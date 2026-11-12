# SPDX-License-Identifier: GPL-2.0-or-later

if(NOT UML_APPLE_PLATFORM MATCHES "^ios" OR
   NOT UML_BUILD_KERNEL_RUNNER OR NOT UML_BUILD_GPU OR
   NOT UML_BUILD_AUDIO OR NOT UML_BUILD_NETWORK_PROVIDER)
    message(FATAL_ERROR
        "LinuxedRuntime requires the iOS runner, GPU, audio, and network")
endif()

if(NOT UML_ACTIVE_KERNEL_ARTIFACT_TARGET OR
   NOT TARGET "${UML_ACTIVE_KERNEL_ARTIFACT_TARGET}")
    message(FATAL_ERROR
        "LinuxedRuntime requires a validated prebuilt kernel artifact")
endif()
get_target_property(_linuxed_artifact_family
    "${UML_ACTIVE_KERNEL_ARTIFACT_TARGET}" UML_ARTIFACT_FAMILY)
get_target_property(_linuxed_kernel_image
    "${UML_ACTIVE_KERNEL_ARTIFACT_TARGET}" UML_KERNEL_IMAGE)
# The import verified the artifact as release series 6.18 with 4 KiB pages.
if(_linuxed_artifact_family STREQUAL "mainline-6.18")
    set(LINUXED_RUNTIME_GUEST_FLAVOR
        LINUXED_RUNTIME_GUEST_LINUX)
else()
    message(FATAL_ERROR
        "LinuxedRuntime requires the mainline-6.18 artifact")
endif()
set(LINUXED_KERNEL_RELEASE_COMPONENT 6_18)
set(LINUXED_KERNEL_PAGE_VARIANT 4K)
set(LINUXED_RUNTIME_FRAMEWORK_NAME
    "KRuntime_${LINUXED_KERNEL_RELEASE_COMPONENT}_${LINUXED_KERNEL_PAGE_VARIANT}")
string(REPLACE "_" "-" _linuxed_runtime_bundle_component
    "${LINUXED_RUNTIME_FRAMEWORK_NAME}")

execute_process(
    COMMAND "${Python3_EXECUTABLE}" -B
        "${PROJECT_SOURCE_DIR}/Linuxed/scripts/verify-signed-kernel-carrier.py"
        --image "${_linuxed_kernel_image}"
    RESULT_VARIABLE _linuxed_carrier_result
    OUTPUT_VARIABLE _linuxed_carrier_output
    ERROR_VARIABLE _linuxed_carrier_error)
if(NOT _linuxed_carrier_result EQUAL 0)
    message(FATAL_ERROR
        "Linuxed kernel is unsafe for the signed iOS carrier:\n"
        "${_linuxed_carrier_output}${_linuxed_carrier_error}")
endif()

add_library(LinuxedRuntime SHARED
    LinuxedAdbChannel.hpp
    LinuxedConsoleInput.hpp
    LinuxedConsoleOutput.hpp
    LinuxedGuestTimeZone.hpp
    LinuxedKeyWake.hpp
    LinuxedRestartLoop.hpp
    LinuxedRuntime.h
    LinuxedRuntime.mm)
uml_declare_architecture_target(LinuxedRuntime app)

# The automation runtime, which only test and benchmark drivers package, also
# accepts a host-built boot payload and relays a guest campaign's artifacts.
# Linuxed/README.md owns that contract.
set(_linuxed_automation_harness 0)
if(UML_LINUXED_AUTOMATION_HARNESS)
    target_sources(LinuxedRuntime PRIVATE
        LinuxedHarness.hpp
        LinuxedHarness.mm
        LinuxedPayloadFile.hpp)
    set(_linuxed_automation_harness 1)
endif()
# Every automation runtime can be asked to start the
# background job with the guest (LinuxedAutomationJob.hpp).
if(UML_LINUXED_AUTOMATION_HARNESS)
    target_sources(LinuxedRuntime PRIVATE LinuxedAutomationJob.hpp)
    set(_linuxed_automation_job_at_start 1)
else()
    set(_linuxed_automation_job_at_start 0)
endif()
target_include_directories(LinuxedRuntime
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}
    PRIVATE
        ${CMAKE_CURRENT_BINARY_DIR}
        ${PROJECT_SOURCE_DIR}/darwin/api/include
        ${PROJECT_SOURCE_DIR}/darwin/device
        ${PROJECT_SOURCE_DIR}/darwin/emulator/src
        ${PROJECT_SOURCE_DIR}/darwin/device/audio
        ${PROJECT_SOURCE_DIR}/darwin/device/battery
        ${PROJECT_SOURCE_DIR}/darwin/device/gpu
        ${PROJECT_SOURCE_DIR}/darwin/device/input/virtio
        ${PROJECT_SOURCE_DIR}/darwin/device/network/slirp)
target_link_libraries(LinuxedRuntime PRIVATE
    UML::Emulator
    UML::BootInitramfs
    UML::GuestPageConfiguration
    UML::AudioDevice
    UML::VideoDevice
    UML::BatteryDevice
    UML::GpuDevice
    UML::ConsoleDevice
    UML::VsockDevice
    UML::VirtioInput
    UML::NetworkProvider
    "-framework Foundation"
    "-framework Metal"
    "-framework MetalKit"
    "-framework UIKit")
target_compile_definitions(LinuxedRuntime PRIVATE
    LINUXED_RUNTIME_GUEST_FLAVOR=${LINUXED_RUNTIME_GUEST_FLAVOR}
    UML_GPU_SOFTWARE_RENDERER=$<BOOL:${UML_GPU_SOFTWARE_RENDERER}>
    LINUXED_AUTOMATION_HARNESS=${_linuxed_automation_harness}
    LINUXED_AUTOMATION_JOB_AT_START=${_linuxed_automation_job_at_start})
target_link_options(LinuxedRuntime PRIVATE
    "LINKER:-force_load,$<TARGET_FILE:uml_emulator>")
# The framework code signature covers __TEXT pages. The loader aliases the
# ELF's immutable executable pages from this aligned carrier into the
# kernel's runtime-selected native window instead of creating anonymous code.
target_link_options(LinuxedRuntime PRIVATE
    "LINKER:-sectcreate,__TEXT,__uml_elf,${_linuxed_kernel_image}"
    "LINKER:-sectalign,__TEXT,__uml_elf,0x4000")
# The guest boots the accepted aarch64 base archive and the generic per-run
# /init, carried beside the kernel as uml-darwin carries them.
include("${PROJECT_SOURCE_DIR}/tools/rootfs/boot-ramdisk/BootBase.cmake")
uml_select_boot_base(aarch64 _linuxed_boot_base)
set(_linuxed_boot_init
    "${PROJECT_SOURCE_DIR}/tools/rootfs/boot-ramdisk/init")
target_link_options(LinuxedRuntime PRIVATE
    "LINKER:-sectcreate,__TEXT,__uml_boot_base,${_linuxed_boot_base}"
    "LINKER:-sectcreate,__TEXT,__uml_boot_init,${_linuxed_boot_init}")
set_property(TARGET LinuxedRuntime APPEND PROPERTY LINK_DEPENDS
    "${_linuxed_boot_base}" "${_linuxed_boot_init}")
add_dependencies(LinuxedRuntime
    "${UML_ACTIVE_KERNEL_ARTIFACT_TARGET}"
    uml_dependency_prefix_verify)
add_dependencies(LinuxedRuntime uml_ios_network_prefix_verify)
set_property(TARGET LinuxedRuntime APPEND PROPERTY LINK_DEPENDS
    "${_linuxed_kernel_image}")
# The framework's Info.plist (Info.plist.in) names and versions it, as App
# Store validation requires of every embedded framework. The short version is
# the kernel series the framework is named for. The bundle version is the
# loader ABI version the application checks before it loads a runtime, so it
# moves exactly when the application and a runtime stop being interchangeable.
# CMake fills the template from the MACOSX_FRAMEWORK_ properties below.
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/LinuxedRuntime.h"
    _linuxed_api_line
    REGEX "^#define LINUXED_RUNTIME_API_VERSION [0-9]+U$")
if(NOT _linuxed_api_line MATCHES "VERSION ([0-9]+)U$")
    message(FATAL_ERROR
        "LinuxedRuntime.h has no LINUXED_RUNTIME_API_VERSION")
endif()
set(_linuxed_runtime_bundle_version "${CMAKE_MATCH_1}")
string(REPLACE "_" "." _linuxed_runtime_short_version
    "${LINUXED_KERNEL_RELEASE_COMPONENT}")
if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
    message(FATAL_ERROR
        "LinuxedRuntime needs the Apple deployment target for its Info.plist")
endif()

set_target_properties(LinuxedRuntime PROPERTIES
    OUTPUT_NAME "${LINUXED_RUNTIME_FRAMEWORK_NAME}"
    FRAMEWORK TRUE
    FRAMEWORK_VERSION A
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "@loader_path/.."
    INSTALL_RPATH_USE_LINK_PATH FALSE
    MACOSX_FRAMEWORK_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    MACOSX_FRAMEWORK_BUNDLE_NAME "${LINUXED_RUNTIME_FRAMEWORK_NAME}"
    MACOSX_FRAMEWORK_SHORT_VERSION_STRING
        "${_linuxed_runtime_short_version}"
    MACOSX_FRAMEWORK_BUNDLE_VERSION "${_linuxed_runtime_bundle_version}"
    MACOSX_FRAMEWORK_IDENTIFIER
        "com.imxieyi.${_linuxed_runtime_bundle_component}"
    PUBLIC_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/LinuxedRuntime.h"
    XCODE_ATTRIBUTE_DEFINES_MODULE YES
    XCODE_ATTRIBUTE_PRODUCT_MODULE_NAME
        "${LINUXED_RUNTIME_FRAMEWORK_NAME}")

configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/module.modulemap.in"
    "${CMAKE_CURRENT_BINARY_DIR}/module.modulemap"
    @ONLY)

add_custom_command(TARGET LinuxedRuntime POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E make_directory
        "$<TARGET_BUNDLE_DIR:LinuxedRuntime>/Modules"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${CMAKE_CURRENT_BINARY_DIR}/module.modulemap"
        "$<TARGET_BUNDLE_DIR:LinuxedRuntime>/Modules/module.modulemap"
    COMMENT "Installing the versioned Linuxed runtime module map"
    VERBATIM)

# The dSYM, and only the dSYM, also names the kernel's functions at their place
# in the __TEXT,__uml_elf section: the runtime moves a panic's kernel frames
# there so a crash report symbolizes them (runtime/kernel_crash_frames).
add_custom_command(TARGET LinuxedRuntime POST_BUILD
    COMMAND xcrun dsymutil "$<TARGET_FILE:LinuxedRuntime>"
        -o "$<TARGET_BUNDLE_DIR:LinuxedRuntime>.dSYM"
    COMMAND "${Python3_EXECUTABLE}" -B
        "${PROJECT_SOURCE_DIR}/scripts/kernel-dsym-symbols.py"
        --dsym "$<TARGET_BUNDLE_DIR:LinuxedRuntime>.dSYM/Contents/Resources/DWARF/${LINUXED_RUNTIME_FRAMEWORK_NAME}"
        --elf "${_linuxed_kernel_image}"
    BYPRODUCTS
        "${CMAKE_CURRENT_BINARY_DIR}/${LINUXED_RUNTIME_FRAMEWORK_NAME}.framework.dSYM/Contents/Resources/DWARF/${LINUXED_RUNTIME_FRAMEWORK_NAME}"
    COMMENT "Generating Linuxed runtime debug symbols"
    VERBATIM)
