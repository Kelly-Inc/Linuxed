# SPDX-License-Identifier: GPL-2.0-or-later

uml_add_tooling_test(
    NAME linuxed-device-framework-symbols
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/linuxed/test_device_framework_symbols.py
    LABELS linuxed;package
    TIMEOUT 120)

uml_add_tooling_test(
    NAME linuxed-kernel-dsym-symbols
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/linuxed/test_kernel_dsym_symbols.py
    LABELS linuxed;package
    TIMEOUT 180)

uml_add_tooling_test(
    NAME linuxed-device-framework-embed
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/linuxed/test_device_framework_embed.py
    LABELS linuxed;package
    TIMEOUT 120)

uml_add_tooling_test(
    NAME linuxed-ipad-automation-keys
    COMMAND ${Python3_EXECUTABLE}
        ${PROJECT_SOURCE_DIR}/tests/tooling/linuxed/test_ipad_automation_keys.py
    LABELS linuxed
    TIMEOUT 30)

uml_add_tooling_test(
    NAME linuxed-ipad-automation-gestures
    COMMAND ${Python3_EXECUTABLE}
        ${PROJECT_SOURCE_DIR}/tests/tooling/linuxed/test_ipad_automation_gestures.py
    LABELS linuxed
    TIMEOUT 30)

uml_add_tooling_test(
    NAME linuxed-ipad-automation-supervisor
    COMMAND ${Python3_EXECUTABLE}
        ${PROJECT_SOURCE_DIR}/tests/tooling/linuxed/test_ipad_automation_supervisor.py
    LABELS linuxed
    TIMEOUT 60)

uml_add_tooling_test(
    NAME linuxed-audio-interrupter
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/linuxed/test_audio_interrupter.py
    LABELS linuxed
    TIMEOUT 120)

uml_add_tooling_test(
    NAME linuxed-payload-removal
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/linuxed/test_payload_removal.py
    LABELS linuxed
    TIMEOUT 60)

if(TARGET uml-initramfs)
    uml_add_tooling_test(
        NAME linuxed-automation-payload
        COMMAND ${Python3_EXECUTABLE} -B
            ${PROJECT_SOURCE_DIR}/tests/tooling/linuxed/test_automation_payload.py
            --tool $<TARGET_FILE:uml-initramfs>
        LABELS linuxed;boot
        TIMEOUT 60)
endif()
