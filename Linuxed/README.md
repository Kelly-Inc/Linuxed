# Linuxed

Linuxed is the iOS application that runs one Linux guest on the
Darwin runtime. It targets the iOS device, whose slice also runs on an Apple
silicon Mac in Designed for iPad mode, and the iOS Simulator, where the guest
renders on the CPU for UI tests
([`graphics.md`](../docs/graphics.md#ios-simulator-software-renderer)). Build,
launch, and test commands are in
[`testing.md`](../docs/testing.md#apple-builds-and-linuxed).

## Ownership

```text
Linuxed/            SwiftUI application: settings, guest selection, console,
                      microphone setting, background running and picture in
                      picture
Runtime/              runtime framework target
LinuxedTests/       hosted application and runtime tests
LinuxedUITests/     UI tests
LinuxedAutomation/  long-lived UI-automation host for a connected device
AudioInterrupter/     test-support application that takes the audio session
scripts/              launch, packaging, and automation tools
```

The runtime loader, the guest display and its input, the zstd utility
(`ZstdUtil`), the microphone permission and the shader-cache bound are not in
this directory: [`GuestHost/`](../GuestHost/README.md) holds them, compiled
into this application.

## Runtimes and runs

Linuxed uses the `6.18`-series runtime framework `KRuntime_6_18_4K`, with 4 KiB
guest pages. Its name stays stable across patch releases and kernel commits,
and each carries its kernel ELF in signed Mach-O `__TEXT` (see the
[architecture](../docs/architecture.md#memory-and-executable-code)). The
application embeds every framework, links none at launch, and loads exactly
one for the process lifetime. Packaging includes each runtime's dSYM in its
XCFramework and then strips the framework binary with `strip -S`, which drops
the linker's debug map (it names the build host's directories) and keeps the
UUID the dSYM matches. The dSYM alone also names the kernel's functions, at
their place in `__TEXT,__uml_elf` (`scripts/kernel-dsym-symbols.py`).

Linuxed makes one run per launch. A guest that restarts itself is booted
again inside that run, in the same process, and the run returns only when the
guest is over; the application then says how it ended and asks to be
relaunched, and never starts a second run in the same process. The guest runs
on the named `uml-launcher` thread, which leaves the main thread to UIKit and
MetalKit. The restart loop and its guarantees are in
[`../docs/architecture.md`](../docs/architecture.md#guest-lifecycle); the
application learns of a restart from `set_restart_callback` and re-applies what
belongs to a kernel (the page-cache trimming and the vCPU throttle) to the new
one. The defaults for a new launch are in
`Linuxed/Linuxed/EmulatorConfiguration.swift`.

## Memory

The host GPU's budget is fixed at launch from the guest's memory, the process's
memory limit and three launch parameters, and the settings offer no more guest
RAM than the limit leaves for the chosen vCPU count
([architecture](../docs/architecture.md#memory-and-executable-code) owns the
formulas; [graphics](../docs/graphics.md#device-memory-budget) what the budget
bounds). The application states the parameters in the boot request, asks the
runtime for the plan (`plan_gpu_budget`) before the run and shows a dismissible
notice when the limit leaves the GPU less than its floor; nothing refuses a
launch for lack of memory. The settings ask the loader
(`linuxed_runtime_loader_maximum_guest_memory_mib`) for the RAM bound and a
new configuration's guest RAM
(`linuxed_runtime_loader_default_guest_memory_mib` at the loaded vCPU count,
which also keeps the GPU 1 GiB on a device that offers 4 GiB), because the
runtime framework is loaded once per process. The parameters default to the
conservative launch set the default is measured with; the RAM bound counts none
of them. The `LINUXED_GPU_BUDGET_*_MIB` and `LINUXED_GUEST_MEMORY_MIB`
environment variables state values for one measurement launch and are never
stored.

## Guest storage

A Linux guest boots an image file in the application's Documents directory:
the one the settings name, or, while they name none, the accepted KDE desktop
image `kde-20260929-r2.erofs`
([`tools/rootfs/desktop`](../tools/rootfs/desktop/README.md)). A name the
settings already store is kept, and every image in Documents stays selectable.

Launch does not compare kernel, runtime, or rootfs release identities; missing
or malformed inputs fail at their ordinary file or image boundary. Compressed delivery is an application concern: `ZstdUtil`
publishes its destination only after a complete decode.

A guest normally runs on the gadget engine. Launched with JIT enabled through
StikDebug, using its `universal.js` script, Linuxed runs the arm64 JIT engine
instead ([architecture](../docs/architecture.md#executable-code)); the
App Store runtime never does.

## Guest boot

A Linux run boots the base archive the runtime embeds
([`tools/rootfs/boot-ramdisk`](../tools/rootfs/boot-ramdisk/README.md))
followed by a segment holding the generic per-run `/init` and its
`/boot.env`; the runtime writes that initrd to its temporary directory and
removes it when the run returns. The parameters mount the image read-only on
`ubd0` beneath an overlay whose writable layer is an ext4 filesystem on `ubd1`:
the sparse `<image>.changes` file beside the image in Documents, which the
application creates once and keeps, so the guest's changes persist; deleting it
starts the image afresh. `/init` then switches root into the
image's own `/sbin/init`, which boots `graphical.target`.

Nothing is typed on the console and the runtime edits no image: accounts,
device groups, getty and display-manager policy, network and resolver belong
to the image. The KDE, Phrog and postmarketOS images Linuxed boots carry
that setup ([`tools/rootfs/desktop`](../tools/rootfs/desktop/README.md)); the
unified `rootfs.erofs` carries none of it and boots to its own defaults.

## Automation runs

The release runtime accepts no host payload and carries no test campaign.
Test and benchmark drivers package the automation variant instead; the
packaging script
(`scripts/package-ios-frameworks.sh`) checks that a release runtime carries
none of the settings below.

- **Linux automation**: the `linuxed-ios-device-automation` preset
  (`UML_LINUXED_AUTOMATION_HARNESS`), packaged with `--automation`. Only it
  reads `LINUXED_BOOT_PAYLOAD` (a plain file name in Documents: a padded newc
  segment of at most 64 MiB, written by `uml-initramfs`, appended after the
  runtime's own so its files replace the runtime's), `LINUXED_SYSTEMD_UNIT`
  (the target booted instead of `graphical.target`) and
  `LINUXED_PAYLOAD_REMOVE=1` (the runtime deletes the payload once it holds
  it, because `devicectl` cannot remove a file in an application container). A
  payload also attaches the artifact relay, whose frames the runtime prints on
  standard output. `tests/integration/support/linuxed.py` writes payloads for
  the lanes in [`testing.md`](../docs/testing.md#apple-builds-and-linuxed)
  and [`tests/perf/README.md`](../tests/perf/README.md).
- The automation runtime also reads `LINUXED_BACKGROUND_JOB_AT_START` and
  `LINUXED_BACKGROUND_HOLD_DELAY_MS`, which start a background job with the
  guest and move the GPU hold for a measurement; the packaging script refuses a
  release runtime that contains their names.

## Devices and display

Linuxed attaches:

- an absolute touchscreen and an evdev keyboard (Linux key codes 1 through
  127, plus Back and Home);
- Virtio-Sound playback and capture, which records silence unless the user
  turns on Microphone;
- a Virtio battery reflecting the phone's battery level and charging state,
  which the guest sees as a power supply;
- SLiRP networking from the verified iOS prefix;
- a Virtio vsock device ([the device](../darwin/device/vsock/README.md)), the
  last Virtio device, through which the application opens streams to guest
  ports (`connect_vsock`, runtime API 19; the guest cannot connect to the
  application);
- a Virtio-GPU Metal framebuffer; and
- the guest's `ttyS0` stream mirrored to a terminal view.

With Remote display over USB on in Settings, the runtime serves the guest's
display over VNC on the device's loopback port 5900
(`darwin/device/gpu/remote_display.hpp`), and a computer reaches it through
the USB tunnel (`iproxy 5900 5900`); the viewer's keyboard and mouse drive the
guest's VNC input devices. It takes the frame mirror, so Picture in Picture
does not start while it runs, and the App Store runtime has none of it.

A Linux guest's SLiRP link forwards the device's loopback port 2222 to the
guest's port 22, unless `LINUXED_HOST_FORWARD` names another forward. While
an external screen (AirPlay) is connected, the framebuffer moves to it, the
guest is resized to that screen, and the phone becomes a touchpad and
keyboard: the application draws a cursor there and sends each press as a
touch at the cursor (`ExternalDisplay.swift`).

Point display mode maps safe-area points to guest pixels at 160 DPI; Retina
mode multiplies both geometry and density by `nativeScale`. The GPU's EDID uses
that launch geometry.
The touchscreen's absolute range is fixed at 0 through 32767 on both axes, and
Linuxed maps the guest's visible rectangle in the view onto it.

A host short of the space a hibernation image takes quiesces with
`quiesce_resident` (runtime API 25), which keeps the guest's RAM in the process
([`docs/architecture.md`](../docs/architecture.md#hibernation)).

A contact the host takes away, rather than ends (UIKit's cancelled touches, a
display mode change, the view leaving its window), is cancelled with
`cancel_touch` (runtime API 24), not released: the touchscreen turns the slot
into a palm before the lift, so libinput reports a cancelled touch, and no tap or click follows (`guest-touch-cancel`,
[`docs/testing.md`](../docs/testing.md)). Known limit: X11 has no per-touch
cancel, so an X11 application under Xwayland can still read a cancelled touch
as a click.

The Metal and Mesa shader cache policies are in
[`graphics.md`](../docs/graphics.md#metal-shader-cache). The guest view follows
the scene's geometry (windows, tiling, Slide Over, Full Screen Apps and
rotation). Linuxed runs one guest per process and so has one window: its
scene manifest does not support multiple scenes.

### Microphone

The Microphone switch in Emulator settings is off by default; while it is off,
or iOS has not granted access, a guest that records gets silence and nothing
opens the microphone. Turning it on is the one place iOS is asked for access
(`MicrophoneSetting`); the application then tells the runtime
(`set_microphone`), which never asks. A guest kept running in the background
may keep recording under the `audio` background mode.
[`../darwin/device/audio/README.md`](../darwin/device/audio/README.md#microphone)
owns the device side.

## Lifecycle

Linuxed asks the guest to write back when the application loses focus,
quiesces it before the application is backgrounded or terminated, and resumes
it on foregrounding. A key press also wakes a guest that suspended itself, as a
phone wakes to its keyboard; a touch does not. The runtime side of sync,
quiesce, resume, and wake is in
[`../docs/architecture.md`](../docs/architecture.md#guest-lifecycle).

iOS revokes the host GPU within seconds of `didEnterBackground`, and a guest
request that reached Metal afterwards would make the guest's Vulkan device
lost for good. The application therefore holds the guest's GPU requests
(`GuestGPUHold`) inside `didEnterBackground`, before it quiesces, and releases
them when it returns to the foreground. The hold and the quiesce share the
handler's four-second budget; the quiesce carries on under the `guest-sync`
background task. Guest page-cache trimming stays off in the foreground, and
quiescing trims once by itself.

On a device the quiesce ends by hibernating the guest's RAM, so that a paused
Linuxed no longer carries the guest's wired memory
([`../docs/architecture.md`](../docs/architecture.md#hibernation));
`LINUXED_GUEST_HIBERNATION=off|on` overrides it. iOS may still end a
suspended application, and the guest goes with it: a marker file records the
background edge, and the next launch says the guest restarted because
Linuxed was closed in the background.

### Keeping a guest running in the background

A guest pauses in the background unless its owner chose otherwise. Settings
holds one mode per guest, stored under the guest's root filesystem name, and
`off` is the default because running costs battery. `BackgroundController`
decides what the lifecycle edges do and acts only through
`BackgroundEffects`, which the unit tests replace.

- `pictureInPicture` keeps the guest running while iOS shows its display in a
  Picture in Picture window. The runtime mirrors the display to a sink the
  application sets (`linuxed_runtime_loader_set_frame_sink`,
  [`graphics.md`](../docs/graphics.md)), which feeds an
  `AVSampleBufferDisplayLayer`. It needs the `audio` background mode in
  `Info.plist` and a playback audio session that mixes with other audio.
- `keepRunning` keeps a guest working without a window for a time its owner
  chose, through one `BGContinuedProcessingTask` (`BackgroundJob`) that the
  user starts with a button tap. iOS grants that task no GPU, so the guest's GPU
  requests stay held for the whole stay.
- A guest kept running has its vCPU threads at background priority
  (`set_background_throttle`) and trims its page cache periodically
  (`set_page_cache_trimming`). `BackgroundPolicy.swift` and `GuestGPUHold.swift` document the order of the
  edges.

### Low space on the device

A guest's disk grows as the guest writes (the Linux overlay in the temporary
directory), and a write the device cannot take
stops the guest. The thresholds and the pause itself are
[GuestHostCore](../GuestHost/README.md).

- A start needs room for the guest's first writes (`StartSpace`: 1.5 GiB). On a device short of it a
  notice covers the guest views, nothing starts, and Check again tries once
  more.
- While a run is on, `GuestSpacePause` reads the free space now and then and
  pauses the guest below 1 GiB. The runtime suspends it with its RAM kept in
  the process (`quiesce_resident`), because a hibernation image is the write
  the device has no room for; the guest's processor time standing still
  confirms the suspension, and a screen over the guest offers Resume and Shut
  down. A guest that does not hold still is called so, with Shut down and
  Check again.
- Resume reads the space again and wakes the guest at 1.5 GiB or more. Shut
  down is the run's stop, the same as leaving the guest: the suspension
  already wrote the guest's storage back, nothing is asked of the guest, and
  the run ends with the notice that the guest shut down. Linuxed has no
  clean power-off request.
- No lifecycle edge wakes a paused guest. While `BackgroundController
  .spaceHeld`, an edge holds the guest's GPU and does nothing else, in every
  background mode, so the guest stays suspended and resident in the
  background; the Picture in Picture window and the keep-running job end when
  the pause begins. The watch reads the space only while the policy leaves
  the guest running.
- `LINUXED_SPACE_HARNESS=1` makes a file `free-space-mib` in Documents,
  holding a number, stand for the device's free space while it exists, and a
  file `space-answer` there (`resume`, `shutdown` or `check`) answer the
  screen once it offers that answer, so a test drives the pause without
  filling the disk.

## Statistics

An application that shows how hard the guest works asks the runtime, which
measures nothing between calls (runtime API 20, `read_statistics` and
`read_guest_memory`). Two readings of one boot give the share of the guest's
processors that computed and the rate of presented frames.
`read_guest_memory` asks the guest kernel through the management console, so it
is never sent where it could wake a guest that sleeps (`-EAGAIN`) and is called
away from the main thread. `LinuxedStatistics.hpp` holds the rules, with
`linuxed-statistics` as their test. The reading also counts the graphics
allocations the host has refused the guest (`gpu_memory_refusals`, runtime API
26) and the host GPU's memory budget with the usage it refuses by
(`gpu_memory_budget_bytes` and `gpu_memory_used_bytes`, runtime API 27);
Linuxed reads none of them.
`read_graphics_memory` (runtime API 28) adds the budget's holders by guest
process, and whether the guest's own low-memory killer reclaims them
(`guest_reclaims`, API 29;
[`docs/graphics.md`](../docs/graphics.md#device-memory-budget)).

## Simulator

The Simulator build is for UI tests of the application.
Configure and build a `linuxed-ios-simulator*` runtime preset, package it with
`scripts/package-ios-frameworks.sh --sdk simulator`, and build the scheme for a
concrete Simulator, or run the tests with `scripts/run-ios-simulator-tests.sh`
([`docs/testing.md`](../docs/testing.md#apple-builds-and-linuxed)). The
Simulator renders on the CPU
([`graphics.md`](../docs/graphics.md#ios-simulator-software-renderer)).

## Scripts

Each script documents its options in `--help` or its header. One fact the
headers do not make obvious: `audio-interrupter.py build` signs
with the team of
[`GuestHost/Config/Signing.local.xcconfig`](../GuestHost/README.md#signing) or
`UML_DEVELOPMENT_TEAM`.
