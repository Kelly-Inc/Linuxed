// SPDX-License-Identifier: GPL-2.0-or-later

#import "LinuxedRuntimeLoader.h"

#include "../../darwin/platform/apple/os_memory_limit.hpp"
#include "../../darwin/runtime/guest_memory_budget.hpp"

#import <Foundation/Foundation.h>
#include <atomic>
#include <cerrno>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <mutex>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>

namespace {

std::mutex selectionMutex;
std::atomic<const linuxed_runtime_api*> selectedApi;
uint32_t selectedFlavor;
bool selectionAttempted;
#ifndef UML_APP_STORE_APPLICATION
/* The selected runtime's automation extensions (LinuxedRuntime.h), or null:
 * a release runtime does not export them. */
int (*automationJobAtStart)(void);
int (*automationHoldDelayMs)(void);
#endif
/* The runtime relay can still call into the loader while exit() destroys
 * ordinary statics. Keep its lock and retained handler alive together. */
struct ConsoleOutputHandlerState final {
    std::mutex mutex;
    LinuxedConsoleOutputHandler handler {nil};
};
ConsoleOutputHandlerState& consoleOutput = *new ConsoleOutputHandlerState;
/* The handler is read on the runtime's callback path, under the runtime's own
 * lock, so it has a mutex of its own that is held only to copy it. Changing
 * the registration, which takes the runtime's lock, is serialized by the
 * other one, which the callback path never takes. */
std::mutex restartHandlerMutex;
std::mutex restartRegistrationMutex;
LinuxedRestartHandler restartHandler;

void forwardConsoleOutput(
    void*,
    const void* buffer,
    std::size_t length)
{
    if (buffer == nullptr || length == 0U)
        return;
    NSData* data = [NSData dataWithBytes:buffer length:length];
    LinuxedConsoleOutputHandler handler;
    {
        std::lock_guard lock(consoleOutput.mutex);
        handler = consoleOutput.handler;
    }
    if (handler == nil)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(data);
    });
}

void updateConsoleOutputForwarder(const linuxed_runtime_api* runtime)
{
    std::lock_guard lock(consoleOutput.mutex);
    runtime->set_console_output_callback(
        consoleOutput.handler == nil ? nullptr : forwardConsoleOutput,
        nullptr);
}

/* Runs on a runtime thread, inside the runtime's call, so it only hands the
 * event to the main queue. */
void forwardRestart(
    void*,
    uint32_t event,
    uint32_t restartCount)
{
    LinuxedRestartHandler handler;
    {
        std::lock_guard lock(restartHandlerMutex);
        handler = restartHandler;
    }
    if (handler == nil)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(event, restartCount);
    });
}

void updateRestartForwarder(const linuxed_runtime_api* runtime)
{
    std::lock_guard registration(restartRegistrationMutex);
    bool wanted;
    {
        std::lock_guard lock(restartHandlerMutex);
        wanted = restartHandler != nil;
    }
    runtime->set_restart_callback(wanted ? forwardRestart : nullptr, nullptr);
}

[[noreturn]] void guestTimerMaskFailure() noexcept
{
    static constexpr char message[] =
        "Linuxed: unable to isolate the UML timer signal\n";
    (void)::write(STDERR_FILENO, message, sizeof(message) - 1U);
    _exit(127);
}

void blockGuestTimer() noexcept
{
    sigset_t blocked;
    if (sigemptyset(&blocked) != 0 ||
        sigaddset(&blocked, SIGALRM) != 0 ||
        ::pthread_sigmask(SIG_BLOCK, &blocked, nullptr) != 0)
        guestTimerMaskFailure();
}

/*
 * The process-directed early ITIMER_REAL calibration must not land on a
 * UIKit or Swift worker. This hook stays in the always-linked application so
 * it runs before main even though the selected emulator framework is loaded
 * later. Only the kernel's vCPU0 carrier temporarily unmasks SIGALRM.
 */
__attribute__((constructor)) void isolateGuestTimerFromApplicationThreads()
{
    blockGuestTimer();
}

/* The flavour leads the framework name. Linux additionally requires a numeric
 * release after its prefix because the specialized names share its stem. */
[[nodiscard]] NSString* flavorPrefix(uint32_t guestFlavor)
{
    switch (guestFlavor) {
    case LINUXED_RUNTIME_GUEST_LINUX:
        return @"KRuntime_";
    case LINUXED_RUNTIME_GUEST_ANDROID:
        return @"KRuntime_Android_";
    default:
        return nil;
    }
}

[[nodiscard]] bool matchesFlavor(
    NSString* name,
    NSString* prefix,
    uint32_t guestFlavor)
{
    if (![name hasPrefix:prefix])
        return false;
    if (guestFlavor != LINUXED_RUNTIME_GUEST_LINUX)
        return true;

    NSUInteger releaseIndex = prefix.length;
    if (name.length <= releaseIndex)
        return false;
    unichar releaseFirst = [name characterAtIndex:releaseIndex];
    return releaseFirst >= '0' && releaseFirst <= '9';
}

[[nodiscard]] NSURL* findRuntimeFramework(
    NSString* prefix,
    uint32_t guestFlavor)
{
    NSURL* frameworks = NSBundle.mainBundle.privateFrameworksURL;
    if (frameworks == nil)
        return nil;

    NSError* error = nil;
    NSArray<NSURL*>* contents = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:frameworks
        includingPropertiesForKeys:@[NSURLIsDirectoryKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles
        error:&error];
    if (contents == nil) {
        std::fprintf(
            stderr,
            "Linuxed: cannot inspect embedded frameworks: %s\n",
            error.localizedDescription.UTF8String ?: "unknown error");
        return nil;
    }

    NSMutableArray<NSURL*>* matches = [NSMutableArray array];
    for (NSURL* candidate in contents) {
        NSString* name = candidate.lastPathComponent;
        if (matchesFlavor(name, prefix, guestFlavor) &&
            [name hasSuffix:@"_4K.framework"])
            [matches addObject:candidate];
    }
    [matches sortUsingComparator:^NSComparisonResult(NSURL* first, NSURL* second) {
        return [first.lastPathComponent compare:second.lastPathComponent];
    }];
    if (matches.count != 1U) {
        std::fprintf(
            stderr,
            "Linuxed: expected one embedded %s4K runtime framework, "
            "found %lu\n",
            prefix.UTF8String,
            static_cast<unsigned long>(matches.count));
        return nil;
    }
    return matches.firstObject;
}

/* Every embedded runtime has 4 KiB guest pages; a framework that says
 * otherwise is stale. */
[[nodiscard]] bool validApi(
    const linuxed_runtime_api* api,
    uint32_t guestFlavor)
{
    if (api == nullptr ||
        api->abi_version != LINUXED_RUNTIME_API_VERSION ||
        api->struct_size < sizeof(linuxed_runtime_api) ||
        api->guest_page_size != 4096U ||
        api->guest_flavor != guestFlavor ||
        api->run == nullptr ||
        api->request_stop == nullptr ||
        api->sync == nullptr ||
        api->quiesce == nullptr ||
        api->resume == nullptr ||
        api->send_touch == nullptr ||
        api->send_key == nullptr ||
        api->set_console_output_callback == nullptr ||
        api->send_console_input == nullptr ||
        api->set_gpu_hold == nullptr ||
        api->set_frame_sink == nullptr ||
        api->set_background_throttle == nullptr ||
        api->set_page_cache_trimming == nullptr ||
        api->set_microphone == nullptr ||
        api->set_restart_callback == nullptr ||
        api->guest_display_active == nullptr ||
        api->plan_gpu_budget == nullptr ||
        api->connect_vsock == nullptr ||
        api->read_statistics == nullptr ||
        api->read_guest_memory == nullptr ||
        api->cancel_touch == nullptr ||
        api->quiesce_resident == nullptr ||
        api->read_graphics_memory == nullptr) {
        std::fputs("Linuxed: runtime API validation failed\n", stderr);
        return false;
    }
    return true;
}

/* `prefix` names the framework for `guestFlavor`; the caller has resolved it.
 * The handle stays loaded for the life of the process. */
[[nodiscard]] int loadRuntime(NSString* prefix, uint32_t guestFlavor)
{
    NSURL* framework = findRuntimeFramework(prefix, guestFlavor);
    NSBundle* bundle = framework == nil ? nil : [NSBundle bundleWithURL:framework];
    NSString* executable = bundle.executablePath;
    if (executable == nil) {
        std::fputs("Linuxed: selected runtime has no framework executable\n", stderr);
        return -1;
    }

    dlerror();
    void* handle = dlopen(executable.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (handle == nullptr) {
        const char* error = dlerror();
        std::fprintf(
            stderr,
            "Linuxed: cannot load selected runtime: %s\n",
            error == nullptr ? "unknown dlopen error" : error);
        return -1;
    }

    dlerror();
    void* symbol = dlsym(handle, "linuxed_runtime_get_api_v28");
    const char* symbolError = dlerror();
    if (symbol == nullptr || symbolError != nullptr) {
        std::fprintf(
            stderr,
            "Linuxed: selected runtime lacks API v28: %s\n",
            symbolError == nullptr ? "symbol unavailable" : symbolError);
        (void)dlclose(handle);
        return -1;
    }
    const auto getter = reinterpret_cast<
        const linuxed_runtime_api* (*)(void)>(symbol);
    const linuxed_runtime_api* api = getter();
    if (!validApi(api, guestFlavor)) {
        (void)dlclose(handle);
        return -1;
    }

    updateConsoleOutputForwarder(api);
    updateRestartForwarder(api);
#ifndef UML_APP_STORE_APPLICATION
    /* Optional: only a runtime built for automation has it. */
    automationJobAtStart = reinterpret_cast<int (*)(void)>(
        dlsym(handle, "linuxed_runtime_automation_job_at_start"));
    (void)dlerror();
    automationHoldDelayMs = reinterpret_cast<int (*)(void)>(
        dlsym(handle, "linuxed_runtime_automation_hold_delay_ms"));
    (void)dlerror();
#endif
    selectedFlavor = guestFlavor;
    selectedApi.store(api, std::memory_order_release);
    std::printf(
        "Linuxed: loaded runtime %s\n",
        framework.lastPathComponent.UTF8String);
    return 0;
}

[[nodiscard]] const linuxed_runtime_api* api() noexcept
{
    return selectedApi.load(std::memory_order_acquire);
}

} // namespace

extern "C" int linuxed_runtime_loader_select(uint32_t guestFlavor)
{
    NSString* prefix = flavorPrefix(guestFlavor);
    if (prefix == nil) {
        std::fprintf(
            stderr,
            "Linuxed: unsupported guest flavour %u\n",
            guestFlavor);
        return -1;
    }

    std::lock_guard lock(selectionMutex);
    if (api() != nullptr)
        return selectedFlavor == guestFlavor ? 0 : -1;
    if (selectionAttempted)
        return -1;
    selectionAttempted = true;
    return loadRuntime(prefix, guestFlavor);
}

extern "C" int linuxed_runtime_loader_run(
    MTKView* view,
    const linuxed_runtime_boot* boot)
{
    const linuxed_runtime_api* runtime = api();
    if (runtime == nullptr) {
        std::fputs("Linuxed: no runtime framework is selected\n", stderr);
        return -1;
    }
    return runtime->run(view, boot);
}

extern "C" void linuxed_runtime_loader_request_stop(void)
{
    const linuxed_runtime_api* runtime = api();
    if (runtime != nullptr)
        runtime->request_stop();
}

extern "C" int linuxed_runtime_loader_sync(void)
{
    const linuxed_runtime_api* runtime = api();
    return runtime == nullptr ? -1 : runtime->sync();
}

extern "C" int linuxed_runtime_loader_quiesce(void)
{
    const linuxed_runtime_api* runtime = api();
    return runtime == nullptr ? -1 : runtime->quiesce();
}

extern "C" int linuxed_runtime_loader_quiesce_resident(void)
{
    const linuxed_runtime_api* runtime = api();
    return runtime == nullptr ? -1 : runtime->quiesce_resident();
}

extern "C" void linuxed_runtime_loader_resume(void)
{
    const linuxed_runtime_api* runtime = api();
    if (runtime != nullptr)
        runtime->resume();
}

extern "C" int linuxed_runtime_loader_set_gpu_hold(int held)
{
    const linuxed_runtime_api* runtime = api();
    return runtime == nullptr ? -1 : runtime->set_gpu_hold(held);
}

extern "C" int linuxed_runtime_loader_set_background_throttle(int enabled)
{
    const linuxed_runtime_api* runtime = api();
    return runtime == nullptr ? -1 : runtime->set_background_throttle(enabled);
}

#ifndef UML_APP_STORE_APPLICATION
extern "C" int linuxed_runtime_loader_set_frame_sink(
    linuxed_runtime_frame_sink sink,
    void* context,
    uint32_t maximumWidth,
    uint32_t framesPerSecond)
{
    const linuxed_runtime_api* runtime = api();
    return runtime == nullptr ?
        -1 :
        runtime->set_frame_sink(sink, context, maximumWidth, framesPerSecond);
}
#endif

extern "C" int linuxed_runtime_loader_set_page_cache_trimming(int enabled)
{
    const linuxed_runtime_api* runtime = api();
    return runtime == nullptr ? -1 : runtime->set_page_cache_trimming(enabled);
}

extern "C" int linuxed_runtime_loader_plan_gpu_budget(
    uint32_t guestMemoryMiB,
    uint32_t guestProcessorCount,
    uint32_t applicationMiB,
    uint32_t engineMiB,
    uint32_t headroomMiB,
    linuxed_runtime_gpu_budget* plan)
{
    const linuxed_runtime_api* runtime = api();
    return runtime == nullptr ?
        -1 :
        runtime->plan_gpu_budget(
            guestMemoryMiB,
            guestProcessorCount,
            applicationMiB,
            engineMiB,
            headroomMiB,
            plan);
}

namespace {

linuxed_launch_memory_set launchMemorySet(
    const uml::runtime::guest_memory::LaunchMemorySet& set)
{
    namespace budget = uml::runtime::guest_memory;
    return {
        .application_mib =
            static_cast<uint32_t>(set.application / budget::mebibyte),
        .engine_mib =
            static_cast<uint32_t>(set.engine_rest / budget::mebibyte),
        .headroom_mib =
            static_cast<uint32_t>(set.headroom / budget::mebibyte),
    };
}

uml::runtime::guest_memory::LaunchMemorySet launchMemorySet(
    linuxed_launch_memory_set parameters)
{
    return uml::runtime::guest_memory::launch_memory_mib(
        parameters.application_mib,
        parameters.engine_mib,
        parameters.headroom_mib);
}

} // namespace

extern "C" linuxed_launch_memory_set
linuxed_runtime_loader_launch_memory_set(void)
{
    namespace budget = uml::runtime::guest_memory;
    static_assert(
        budget::launch_memory_set.application % budget::mebibyte == 0 &&
            budget::launch_memory_set.engine_rest % budget::mebibyte == 0 &&
            budget::launch_memory_set.headroom % budget::mebibyte == 0,
        "the launch set is whole mebibytes");
    return launchMemorySet(budget::launch_memory_set);
}

extern "C" linuxed_launch_memory_set
linuxed_runtime_loader_maximum_memory_set(void)
{
    return launchMemorySet(
        uml::runtime::guest_memory::maximum_memory_set);
}

extern "C" uint32_t linuxed_runtime_loader_application_vcpu_limit(
    uint32_t physicalProcessorCount)
{
    return uml::runtime::guest_memory::application_vcpu_limit(
        physicalProcessorCount);
}

extern "C" uint32_t linuxed_runtime_loader_maximum_guest_memory_mib_for_limit(
    uint64_t limitBytes,
    uint32_t guestProcessorCount,
    linuxed_launch_memory_set parameters)
{
    return uml::runtime::guest_memory::maximum_guest_memory_mib(
        limitBytes, guestProcessorCount, launchMemorySet(parameters));
}

extern "C" uint32_t linuxed_runtime_loader_maximum_guest_memory_mib(
    uint32_t guestProcessorCount,
    linuxed_launch_memory_set parameters)
{
    return linuxed_runtime_loader_maximum_guest_memory_mib_for_limit(
        uml::platform::os_memory_limit_bytes(),
        guestProcessorCount,
        parameters);
}

extern "C" uint32_t linuxed_runtime_loader_default_guest_memory_mib_for_limit(
    uint64_t limitBytes,
    uint32_t guestProcessorCount,
    linuxed_launch_memory_set parameters)
{
    return uml::runtime::guest_memory::default_guest_memory_mib(
        limitBytes, guestProcessorCount, launchMemorySet(parameters));
}

extern "C" uint32_t linuxed_runtime_loader_default_guest_memory_mib(
    uint32_t guestProcessorCount,
    linuxed_launch_memory_set parameters)
{
    return linuxed_runtime_loader_default_guest_memory_mib_for_limit(
        uml::platform::os_memory_limit_bytes(),
        guestProcessorCount,
        parameters);
}

extern "C" uint32_t
linuxed_runtime_loader_conservative_guest_memory_mib_for_limit(
    uint64_t limitBytes,
    uint32_t guestProcessorCount,
    linuxed_launch_memory_set parameters)
{
    return uml::runtime::guest_memory::conservative_guest_memory_mib(
        limitBytes, guestProcessorCount, launchMemorySet(parameters));
}

extern "C" uint32_t linuxed_runtime_loader_conservative_guest_memory_mib(
    uint32_t guestProcessorCount,
    linuxed_launch_memory_set parameters)
{
    return linuxed_runtime_loader_conservative_guest_memory_mib_for_limit(
        uml::platform::os_memory_limit_bytes(),
        guestProcessorCount,
        parameters);
}

extern "C" uint32_t linuxed_runtime_loader_gpu_budget_mib_for_limit(
    uint64_t limitBytes,
    uint32_t guestMemoryMiB,
    uint32_t guestProcessorCount,
    linuxed_launch_memory_set parameters)
{
    namespace budget = uml::runtime::guest_memory;
    return static_cast<uint32_t>(
        budget::gpu_budget(
            limitBytes,
            guestMemoryMiB,
            guestProcessorCount,
            launchMemorySet(parameters))
            .bytes /
        budget::mebibyte);
}

extern "C" uint32_t linuxed_runtime_loader_gpu_budget_mib(
    uint32_t guestMemoryMiB,
    uint32_t guestProcessorCount,
    linuxed_launch_memory_set parameters)
{
    return linuxed_runtime_loader_gpu_budget_mib_for_limit(
        uml::platform::os_memory_limit_bytes(),
        guestMemoryMiB,
        guestProcessorCount,
        parameters);
}

extern "C" int linuxed_runtime_loader_set_microphone(int enabled)
{
    const linuxed_runtime_api* runtime = api();
    return runtime == nullptr ? -1 : runtime->set_microphone(enabled);
}

extern "C" void linuxed_runtime_loader_send_touch(
    uint32_t slot,
    uint32_t x,
    uint32_t y,
    int pressed)
{
    const linuxed_runtime_api* runtime = api();
    if (runtime != nullptr)
        runtime->send_touch(slot, x, y, pressed);
}

extern "C" void linuxed_runtime_loader_cancel_touch(uint32_t slot)
{
    const linuxed_runtime_api* runtime = api();
    if (runtime != nullptr)
        runtime->cancel_touch(slot);
}

extern "C" void linuxed_runtime_loader_send_key(uint16_t code, int pressed)
{
    const linuxed_runtime_api* runtime = api();
    if (runtime != nullptr)
        runtime->send_key(code, pressed);
}

extern "C" void linuxed_runtime_loader_set_console_output_handler(
    LinuxedConsoleOutputHandler handler)
{
    {
        std::lock_guard lock(consoleOutput.mutex);
        consoleOutput.handler = [handler copy];
    }
    const linuxed_runtime_api* runtime = api();
    if (runtime != nullptr)
        updateConsoleOutputForwarder(runtime);
}

extern "C" void linuxed_runtime_loader_set_restart_handler(
    LinuxedRestartHandler handler)
{
    {
        std::lock_guard lock(restartHandlerMutex);
        restartHandler = [handler copy];
    }
    const linuxed_runtime_api* runtime = api();
    if (runtime != nullptr)
        updateRestartForwarder(runtime);
}

extern "C" int linuxed_runtime_loader_connect_vsock(
    uint32_t port,
    uint32_t timeoutMilliseconds)
{
    const linuxed_runtime_api* runtime = api();
    return runtime == nullptr ?
        -ENODEV :
        runtime->connect_vsock(port, timeoutMilliseconds);
}

#ifndef UML_APP_STORE_APPLICATION
extern "C" int linuxed_runtime_loader_automation_hold_delay_ms(void)
{
    return api() != nullptr && automationHoldDelayMs != nullptr
        ? automationHoldDelayMs()
        : 0;
}
#endif

extern "C" int linuxed_runtime_loader_guest_display_active(void)
{
    const linuxed_runtime_api* runtime = api();
    return runtime == nullptr ? -1 : runtime->guest_display_active();
}

extern "C" int linuxed_runtime_loader_read_statistics(
    linuxed_runtime_statistics* statistics)
{
    const linuxed_runtime_api* runtime = api();
    return runtime == nullptr ? -ENODEV : runtime->read_statistics(statistics);
}

extern "C" int linuxed_runtime_loader_read_graphics_memory(
    linuxed_runtime_graphics_memory* memory)
{
    const linuxed_runtime_api* runtime = api();
    return runtime == nullptr ? -ENODEV : runtime->read_graphics_memory(memory);
}

extern "C" int linuxed_runtime_loader_read_guest_memory(
    linuxed_runtime_guest_memory* memory)
{
    const linuxed_runtime_api* runtime = api();
    return runtime == nullptr ? -ENODEV : runtime->read_guest_memory(memory);
}

#ifndef UML_APP_STORE_APPLICATION
extern "C" int linuxed_runtime_loader_automation_job_at_start(void)
{
    return api() != nullptr && automationJobAtStart != nullptr
        ? automationJobAtStart()
        : 0;
}

extern "C" int linuxed_runtime_loader_send_console_input(
    const void* buffer,
    std::size_t length)
{
    const linuxed_runtime_api* runtime = api();
    if (runtime == nullptr)
        return -1;
    return runtime->send_console_input(buffer, length);
}
#endif
