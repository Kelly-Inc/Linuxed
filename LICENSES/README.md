# Licensing

The project is GPL-2.0-or-later; the root [`LICENSE`](../LICENSE) is the
GPL-2.0 text. The runtime links the GPL-2.0-only Linux kernel into the same
binary, so host code must be GPL-2.0-compatible.

Each file's own SPDX header governs. A file without another header is
GPL-2.0-or-later. The licence texts live here, one per identifier in use,
named `<identifier>.txt`; the GPL-2.0 text is the root `LICENSE`.

## The rule

1. A patch to another project, and a file derived from it, keeps that
   project's licence: the Mesa, virglrenderer and Vulkan patches (MIT,
   BSD-3-Clause, Apache-2.0) and the kernel patches (the kernel's own
   identifiers).
2. Everything else is GPL-2.0-or-later: the host runtime, the applications,
   the kernel-side sources, the build-host tooling and the tests.

A first-party file derived from kernel code keeps the kernel's identifier,
GPL-2.0-only, or GPL-2.0-only WITH Linux-syscall-note for a uapi header, and
records the reason in its own header. The deprecated identifiers `GPL-2.0` and
`GPL-2.0+` are not used in first-party headers.

## Carried content

These keep the licence they came with, under their own notices:

- `dependencies/patches/`, `tools/rootfs/*/patches/` and `kernel/*/patches/`:
  patch files carry no header and keep the patched project's licence. A
  series manifest (`series.tsv`) is this project's own generated metadata and
  is GPL-2.0-or-later.
- `tests/unit/x86_64/corpus/LICENSE.*`: the notice of the third-party material
  beside it.
- The Khronos must-pass lists under `tests/integration/gpu/`, which state their
  own licence.

## Checking

`repository-license-headers` (a tooling test) enforces the rule by location:
every source file carries a header with an identifier allowed where it lives,
none is deprecated, and `LICENSE` and this directory hold a text for every
identifier in use. A reviewed exception goes in
`tests/tooling/cmake/license-header-exceptions.tsv` with its reason;
`python3 tests/tooling/cmake/check_license_headers.py --list-rules` prints the
locations.
