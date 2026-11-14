// SPDX-License-Identifier: GPL-2.0-or-later
#include "executable_memory.hpp"

#include <sys/mman.h>

#include <libkern/OSCacheControl.h>
#include <os/lock.h>
#include <pthread.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(__APPLE__) && defined(__aarch64__) && TARGET_OS_IOS && \
	!TARGET_OS_SIMULATOR && !defined(UML_APP_STORE_RUNTIME)
#include <csignal>
#include <mach/mach.h>
#include <sys/ucontext.h>
#define UML_JIT_IOS_DEBUGGER_POOL 1
#else
#define UML_JIT_IOS_DEBUGGER_POOL 0
#endif

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

namespace uml::cpu::jit_memory {
namespace {

/* Publication route for MAP_JIT memory.
 *
 * macOS declares pthread_jit_write_protect_np and calls it directly. No iOS
 * product has a publication route: a physical device cannot obtain the
 * entitlement, so JIT memory reports itself unavailable there rather than
 * mapping memory it could never publish into.
 *
 * The Simulator is deliberately held to the same answer even though it runs on
 * macOS and could reach the toggle dynamically. Letting it translate through a
 * path production devices cannot use would make the Simulator unrepresentative
 * of the product it exists to stand in for.
 */
#if defined(__APPLE__) && defined(__aarch64__) && defined(MAP_JIT) && \
	!defined(__IPHONE_OS_VERSION_MAX_ALLOWED)
void jit_write_protect(int enable)
{
	pthread_jit_write_protect_np(enable);
}

constexpr bool jit_publication_supported() noexcept
{
	return true;
}
#else
constexpr void jit_write_protect(int) {}

constexpr bool jit_publication_supported() noexcept
{
	return false;
}
#endif

/* Whether JIT memory comes from the Window below: near this image on macOS,
 * the debugger-blessed pool on an iOS device. */
constexpr bool serves_window() noexcept
{
	return jit_publication_supported() || UML_JIT_IOS_DEBUGGER_POOL;
}

/* Where JIT code lives.
 *
 * An Apple core predicts an indirect branch's target cheaply only when the
 * target lies near the branch. On an M1 Ultra a call through a register and
 * its return cost about 0.7 ns when caller and callee share an aligned
 * 512 MiB block, 1.9 ns when they share an aligned 4 GiB block, and 5 ns or
 * more when they do not. Generated code calls into this image -- FEXCore
 * reaches its x87 softfloat fallbacks that way for every x87 operation -- and
 * jumps between its own allocations, so where a mapping lands decides how fast
 * the code in it runs.
 *
 * The kernel places a mapping at the lowest free range. The 2 GiB between this
 * image and the shared cache fill with the JIT's own data, so a code buffer
 * mapped later in a run landed some 400 GiB away, and the guest process it
 * served ran x87 code a third slower than its neighbours.
 *
 * So the process claims one window, the largest, up to 1.5 GiB in 64 MiB
 * steps, whose lowest free range at or above this image's 512 MiB block lies
 * in its 4 GiB block, and serves every allocation from it, lowest address
 * first. It claims the window when it first asks whether it can run JIT
 * code, which it does when it selects a JIT engine, before its kernel boots:
 * by the first allocation the range is already scattered with small
 * mappings, and the JIT's data reservations claim the rest of it as soon as
 * the first contexts exist. FEXCore keeps a 16 MiB code buffer for each of
 * the eight address spaces each vCPU caches, so ten vCPUs keep 80 of them.
 *
 * MAP_JIT cannot map over an existing range, and a hole in a live window
 * would be the kernel's first choice for an unrelated mapping, so a release
 * keeps the pages mapped and marks them reusable; memory served again may
 * still hold what it held before. When the window is full, or cannot be
 * placed, a mapping goes wherever the kernel puts it.
 */
class Window final {
public:
	void claim() noexcept
	{
		os_unfair_lock_lock(&lock_);
		claim_locked();
		os_unfair_lock_unlock(&lock_);
	}

	/* Serves from mapping, bytes long, instead of a range of its own. */
	void adopt(void *mapping, std::size_t bytes) noexcept
	{
		os_unfair_lock_lock(&lock_);
		if (!claimed_) {
			claimed_ = true;
			base_ = static_cast<std::byte *>(mapping);
			granules_ = std::min(bytes, max_bytes) / granule;
		}
		os_unfair_lock_unlock(&lock_);
	}

	[[nodiscard]] void *allocate(std::size_t size) noexcept
	{
		if (size == 0 || size > max_bytes)
			return nullptr;
		const auto count = granules_for(size);
		os_unfair_lock_lock(&lock_);
		claim_locked();
		const auto first = find(count);
		if (first != none)
			mark(first, count, true);
		os_unfair_lock_unlock(&lock_);
		if (first == none)
			return nullptr;
		void *mapping = base_ + first * granule;
		/* A released range is reusable: the kernel may discard its pages
		 * until it is claimed back. Blessed pool pages are kept as they are. */
		if constexpr (!UML_JIT_IOS_DEBUGGER_POOL)
			(void)madvise(mapping, count * granule, MADV_FREE_REUSE);
		return mapping;
	}

	/* Whether mapping came from the window; if so its pages return to it. */
	[[nodiscard]] bool release(void *mapping, std::size_t size) noexcept
	{
		os_unfair_lock_lock(&lock_);
		std::byte *const base = base_;
		const std::size_t granules = granules_;
		os_unfair_lock_unlock(&lock_);
		auto *const bytes = static_cast<std::byte *>(mapping);
		if (base == nullptr || bytes < base ||
		    bytes >= base + granules * granule)
			return false;
		const auto first =
			static_cast<std::size_t>(bytes - base) / granule;
		const auto count = granules_for(size);
		if (count > granules - first)
			return true;
		/* Marked reusable before it is free, so no later claim can
		 * race the advice. */
		if constexpr (!UML_JIT_IOS_DEBUGGER_POOL)
			(void)madvise(mapping, count * granule, MADV_FREE_REUSABLE);
		os_unfair_lock_lock(&lock_);
		mark(first, count, false);
		os_unfair_lock_unlock(&lock_);
		return true;
	}

private:
	/* The host page on every Apple arm64 product. */
	static constexpr std::size_t granule = 16U * 1024U;
	static constexpr std::size_t step_bytes = 64U * 1024U * 1024U;
	static constexpr std::size_t max_bytes = 24U * step_bytes;
	static constexpr std::uintptr_t prediction_block = std::uintptr_t{1} << 29U;
	static constexpr std::uintptr_t near_block = std::uintptr_t{1} << 32U;
	static constexpr std::size_t none = ~std::size_t{0};

	[[nodiscard]] static constexpr std::size_t granules_for(
		std::size_t size) noexcept
	{
		return (size + granule - 1U) / granule;
	}

	void claim_locked() noexcept
	{
		if (claimed_)
			return;
		claimed_ = true;
		/* An iOS device serves only the pool adopt() handed over. */
		if constexpr (UML_JIT_IOS_DEBUGGER_POOL)
			return;
		if (static_cast<std::size_t>(getpagesize()) > granule)
			return;
		/* Any function of this image locates it. */
		const auto image = reinterpret_cast<std::uintptr_t>(
			&::uml::cpu::jit_memory::allocate);
		const auto hint = image & ~(prediction_block - 1U);
		const auto block = image & ~(near_block - 1U);
		for (auto bytes = max_bytes; bytes != 0; bytes -= step_bytes) {
			void *mapping = mmap(reinterpret_cast<void *>(hint), bytes,
				PROT_READ | PROT_WRITE | PROT_EXEC,
				MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
			if (mapping == MAP_FAILED)
				continue;
			const auto start = reinterpret_cast<std::uintptr_t>(mapping);
			if (start >= block && start - block <= near_block - bytes) {
				base_ = static_cast<std::byte *>(mapping);
				granules_ = bytes / granule;
				return;
			}
			(void)munmap(mapping, bytes);
		}
	}

	[[nodiscard]] std::size_t find(std::size_t count) const noexcept
	{
		std::size_t run = 0;
		for (std::size_t i = 0; i < granules_;) {
			const auto word = used_[i / 64U];
			if (i % 64U == 0 && word == ~std::uint64_t{0}) {
				run = 0;
				i += 64U;
				continue;
			}
			if (((word >> (i % 64U)) & 1U) != 0)
				run = 0;
			else if (++run == count)
				return i + 1U - count;
			++i;
		}
		return none;
	}

	void mark(std::size_t first, std::size_t count, bool used) noexcept
	{
		for (auto i = first; i < first + count; ++i) {
			const auto bit = std::uint64_t{1} << (i % 64U);
			if (used)
				used_[i / 64U] |= bit;
			else
				used_[i / 64U] &= ~bit;
		}
	}

	os_unfair_lock lock_ = OS_UNFAIR_LOCK_INIT;
	bool claimed_{};
	std::byte *base_{};
	std::size_t granules_{};
	std::array<std::uint64_t, max_bytes / granule / 64U> used_{};
};

constinit Window window;

#if UML_JIT_IOS_DEBUGGER_POOL
/* iOS lets a process run code it writes only while a debugger has attached
 * (CS_DEBUGGED), and on a device with the Trusted Execution Monitor only in
 * pages the debugger blessed. The pool follows StikDebug's universal.js
 * protocol: one read-execute range is blessed in a single request, a
 * read-write mirror of the same pages takes the writes, and the debugger
 * then detaches. A process no debugger attached to never traps.
 */
extern "C" int csops(pid_t pid, unsigned int ops, void *status, size_t size);

constexpr std::size_t pool_bytes = std::size_t{1} << 30U;
constinit std::byte *pool_base = nullptr;
constinit std::ptrdiff_t pool_mirror_offset = 0;
volatile std::sig_atomic_t debugger_missed = 0;

void skip_unhandled_break(int, siginfo_t *, void *context)
{
	debugger_missed = 1;
	static_cast<ucontext_t *>(context)->uc_mcontext->__ss.__pc += 4;
}

/* universal.js command x16 with x0 and x1; false when no debugger answered. */
bool debugger_command(unsigned command, void *address, std::size_t size)
{
	struct sigaction previous {};
	struct sigaction handler {};
	handler.sa_sigaction = skip_unhandled_break;
	handler.sa_flags = SA_SIGINFO;
	sigemptyset(&handler.sa_mask);
	sigaction(SIGTRAP, &handler, &previous);
	debugger_missed = 0;
	asm volatile("mov x0, %0\n"
		     "mov x1, %1\n"
		     "mov x16, %2\n"
		     "brk #0xf00d"
		     :
		     : "r"(address), "r"(size),
		       "r"(static_cast<std::uint64_t>(command))
		     : "x0", "x1", "x16", "memory");
	sigaction(SIGTRAP, &previous, nullptr);
	return debugger_missed == 0;
}

bool debugger_attached() noexcept
{
	constexpr unsigned status = 0;
	constexpr std::uint32_t debugged = 0x10000000;
	std::uint32_t flags = 0;
	return csops(getpid(), status, &flags, sizeof flags) == 0 &&
	       (flags & debugged) != 0;
}

bool create_debugger_pool() noexcept
{
	if (!debugger_attached())
		return false;
	/* Near this image, for the branch prediction the Window describes;
	 * anywhere when that range is taken. */
	const auto hint = reinterpret_cast<std::uintptr_t>(&create_debugger_pool) &
			  ~((std::uintptr_t{1} << 29U) - 1U);
	void *executable = mmap(reinterpret_cast<void *>(hint), pool_bytes,
		PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
	if (executable == MAP_FAILED)
		return false;
	constexpr unsigned prepare_region = 1;
	constexpr unsigned detach = 0;
	if (!debugger_command(prepare_region, executable, pool_bytes)) {
		(void)munmap(executable, pool_bytes);
		return false;
	}
	vm_address_t mirror = 0;
	vm_prot_t current = VM_PROT_NONE;
	vm_prot_t maximum = VM_PROT_NONE;
	if (vm_remap(mach_task_self(), &mirror, pool_bytes, 0,
		    VM_FLAGS_ANYWHERE, mach_task_self(),
		    reinterpret_cast<vm_address_t>(executable), FALSE, &current,
		    &maximum, VM_INHERIT_NONE) != KERN_SUCCESS) {
		(void)munmap(executable, pool_bytes);
		return false;
	}
	if (mprotect(reinterpret_cast<void *>(mirror), pool_bytes,
		    PROT_READ | PROT_WRITE) != 0) {
		(void)vm_deallocate(mach_task_self(), mirror, pool_bytes);
		(void)munmap(executable, pool_bytes);
		return false;
	}
	pool_base = static_cast<std::byte *>(executable);
	pool_mirror_offset = reinterpret_cast<std::byte *>(mirror) - pool_base;
	(void)debugger_command(detach, nullptr, 0);
	window.adopt(executable, pool_bytes);
	return true;
}
#endif

} // namespace

bool available() noexcept
{
	static const bool supported = [] {
#if UML_JIT_IOS_DEBUGGER_POOL
		return create_debugger_pool();
#elif defined(__APPLE__) && defined(__aarch64__) && defined(MAP_JIT)
		/* A successful MAP_JIT mapping is necessary but not sufficient:
		 * without a W^X toggle the first store into it faults. Requiring
		 * the publication route keeps this from promising an engine that
		 * would abort on its first translated block.
		 */
		if (!jit_publication_supported())
			return false;
		void *mapping = mmap(nullptr, 16U * 1024U,
			PROT_READ | PROT_WRITE | PROT_EXEC,
			MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
		if (mapping == MAP_FAILED)
			return false;
		(void)munmap(mapping, 16U * 1024U);
		window.claim();
		return true;
#else
		return false;
#endif
	}();
	return supported;
}

void *allocate(std::size_t size) noexcept
{
	if constexpr (serves_window()) {
		if (void *mapping = window.allocate(size); mapping != nullptr)
			return mapping;
	}
	if constexpr (UML_JIT_IOS_DEBUGGER_POOL)
		return nullptr;
	void *mapping = mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC,
		MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
	return mapping == MAP_FAILED ? nullptr : mapping;
}

void release(void *mapping, std::size_t size)
{
	if constexpr (serves_window()) {
		if (window.release(mapping, size))
			return;
	}
	(void)munmap(mapping, size);
}

void *writable_alias(void *code) noexcept
{
#if UML_JIT_IOS_DEBUGGER_POOL
	auto *bytes = static_cast<std::byte *>(code);
	if (pool_base != nullptr && bytes >= pool_base &&
	    bytes < pool_base + pool_bytes)
		return bytes + pool_mirror_offset;
#endif
	return code;
}

void set_writable(bool writable)
{
	jit_write_protect(writable ? 0 : 1);
}

void invalidate_instruction_cache(void *code, std::size_t size)
{
	sys_icache_invalidate(code, size);
}

void *reserve_guarded(std::size_t size) noexcept
{
	const auto guard = static_cast<std::size_t>(getpagesize());
	if (size == 0 || size % guard != 0 || size > SIZE_MAX - 2 * guard)
		return nullptr;
	void *mapping = mmap(nullptr, size + 2 * guard, PROT_NONE,
		MAP_PRIVATE | MAP_ANON, -1, 0);
	if (mapping == MAP_FAILED)
		return nullptr;
	auto *data = static_cast<std::byte *>(mapping) + guard;
	if (mprotect(data, size, PROT_READ | PROT_WRITE) != 0) {
		(void)munmap(mapping, size + 2 * guard);
		return nullptr;
	}
	return data;
}

void release_guarded(void *data, std::size_t size)
{
	const auto guard = static_cast<std::size_t>(getpagesize());
	(void)munmap(static_cast<std::byte *>(data) - guard, size + 2 * guard);
}

} // namespace uml::cpu::jit_memory
