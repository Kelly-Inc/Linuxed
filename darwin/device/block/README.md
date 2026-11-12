# Block device helpers

This directory holds the host-side block helpers that products share:

- `UML::DeviceUbdPath` (`ubd_path.hpp`) is the rule for naming a host file in
  a `ubd<n>=` kernel argument;
- `UML::BootInitramfs` (`boot_initramfs.cpp`) writes the per-run initramfs
  that the [boot ramdisk contract](../../../tools/rootfs/boot-ramdisk/README.md)
  describes.

Unit tests live under `tests/unit/block`.
