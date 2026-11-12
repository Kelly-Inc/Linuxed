# SPDX-License-Identifier: GPL-2.0-or-later

# Linuxed's runtime is an iOS framework, but its console input, the file
# handling of the automation boot payload, the key wake policy and the
# automation launch's ADB authorization decision are plain POSIX and C++ and
# are exercised here on the host.
add_executable(uml_linuxed_console_input_tests console_input_tests.cpp)
target_include_directories(uml_linuxed_console_input_tests PRIVATE
    ${PROJECT_SOURCE_DIR}/Linuxed/Runtime)
uml_add_unit_test(NAME linuxed-console-input
    COMMAND uml_linuxed_console_input_tests
    LABELS linuxed)

add_executable(uml_linuxed_console_output_tests console_output_tests.cpp)
target_include_directories(uml_linuxed_console_output_tests PRIVATE
    ${PROJECT_SOURCE_DIR}/Linuxed/Runtime)
uml_add_unit_test(NAME linuxed-console-output
    COMMAND uml_linuxed_console_output_tests
    LABELS linuxed)

add_executable(uml_linuxed_payload_file_tests payload_file_tests.cpp)
target_include_directories(uml_linuxed_payload_file_tests PRIVATE
    ${PROJECT_SOURCE_DIR}/Linuxed/Runtime)
uml_add_unit_test(NAME linuxed-payload-file
    COMMAND uml_linuxed_payload_file_tests
    LABELS linuxed)

# Which key events wake a guest that suspended itself (a touch never does).
add_executable(uml_linuxed_key_wake_tests key_wake_tests.cpp)
target_include_directories(uml_linuxed_key_wake_tests PRIVATE
    ${PROJECT_SOURCE_DIR}/Linuxed/Runtime)
uml_add_unit_test(NAME linuxed-key-wake
    COMMAND uml_linuxed_key_wake_tests
    LABELS linuxed)

# The run loop of a launch that boots a restarting guest again, with a
# recording machine in place of the guest.
add_executable(uml_linuxed_restart_loop_tests restart_loop_tests.cpp)
target_include_directories(uml_linuxed_restart_loop_tests PRIVATE
    ${PROJECT_SOURCE_DIR}/Linuxed/Runtime
    ${PROJECT_SOURCE_DIR}/darwin/api/include
    ${PROJECT_SOURCE_DIR}/darwin/emulator/src)
uml_add_unit_test(NAME linuxed-restart-loop
    COMMAND uml_linuxed_restart_loop_tests
    LABELS linuxed)

# How an automation launch asks to start the background job with its guest.
add_executable(uml_linuxed_automation_job_tests automation_job_tests.cpp)
target_include_directories(uml_linuxed_automation_job_tests PRIVATE
    ${PROJECT_SOURCE_DIR}/Linuxed/Runtime)
uml_add_unit_test(NAME linuxed-automation-job
    COMMAND uml_linuxed_automation_job_tests
    LABELS linuxed)

# The kernel arguments that carry an Android guest's adb key and the request
# that adbd not listen on TCP, and the limit on the whole kernel command line.
add_executable(uml_linuxed_adb_channel_tests adb_channel_tests.cpp)
target_include_directories(uml_linuxed_adb_channel_tests PRIVATE
    ${PROJECT_SOURCE_DIR}/Linuxed/Runtime)
uml_add_unit_test(NAME linuxed-adb-channel
    COMMAND uml_linuxed_adb_channel_tests
    LABELS linuxed)

# The host's time zone an Android guest is given, and which names the runtime
# lets onto the kernel command line.
add_executable(uml_linuxed_guest_time_zone_tests guest_time_zone_tests.cpp)
target_include_directories(uml_linuxed_guest_time_zone_tests PRIVATE
    ${PROJECT_SOURCE_DIR}/Linuxed/Runtime)
uml_add_unit_test(NAME linuxed-guest-time-zone
    COMMAND uml_linuxed_guest_time_zone_tests
    LABELS linuxed)

# How a statistics reading is composed from the emulator's and the display's
# figures, and when the guest's memory may be asked for.
add_executable(uml_linuxed_statistics_tests statistics_tests.cpp)
target_include_directories(uml_linuxed_statistics_tests PRIVATE
    ${PROJECT_SOURCE_DIR}/Linuxed/Runtime
    ${PROJECT_SOURCE_DIR}/darwin/api/include)
uml_add_unit_test(NAME linuxed-statistics
    COMMAND uml_linuxed_statistics_tests
    LABELS linuxed)
