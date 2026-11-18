#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Turn a Kernarium checkout at the pinned commit into Trolldroid.

Every edit replaces text that must occur exactly once, so a checkout that has
drifted from the pin fails here instead of building something else.
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def fail(message: str) -> None:
    raise SystemExit(f"trolldroid/apply.py: {message}")


def replace_once(path: Path, old: str, new: str, expected: int = 1) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != expected:
        fail(f"{path}: expected {expected} matches, found {count}: {old[:60]!r}")
    path.write_text(text.replace(old, new), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernarium", type=Path, required=True,
                        help="the Kernarium checkout to change in place")
    root = parser.parse_args().kernarium.resolve()
    app = root / "Andarium"
    if not (app / "Andarium.xcodeproj/project.xcproj").is_file():
        fail(f"{root} is not a Kernarium checkout")

    # Mesa's PATH is sealed, so a Homebrew Bison 3 must reach it through the
    # shim directory too, or Mesa runs the system's Bison 2 on its grammars.
    gpu = root / "dependencies/build-apple-gpu.sh"
    replace_once(gpu,
                 'case $BISON_VERSION in\n[3-9].*|[1-9][0-9].*) ;;\n*)\n'
                 '\tBISON_SHIM_DIR="$BUILDS/bison-shim"\n\tmkdir -p -- "$BISON_SHIM_DIR"\n',
                 'BISON_SHIM_DIR="$BUILDS/bison-shim"\nmkdir -p -- "$BISON_SHIM_DIR"\n'
                 'case $BISON_VERSION in\n[3-9].*|[1-9][0-9].*)\n\tln -sf -- "$BISON" "$BISON_SHIM_DIR/bison"\n\t;;\n*)\n')
    replace_once(gpu,
                 '\tMESA_GL_TOOL_PATH="$BISON_SHIM_DIR:$MESA_TOOL_PATH"\n\t;;\nesac\n',
                 '\t;;\nesac\nMESA_GL_TOOL_PATH="$BISON_SHIM_DIR:$MESA_TOOL_PATH"\n')

    # Name, bundle and icon; the device and preview applications share the
    # name and the icon.
    project = app / "Andarium.xcodeproj/project.xcproj"
    replace_once(project, '"INFOPLIST_KEY_CFBundleDisplayName": "Andarium"',
                 '"INFOPLIST_KEY_CFBundleDisplayName": "Trolldroid"', expected=2)
    replace_once(project, '"PRODUCT_BUNDLE_IDENTIFIER": "com.imxieyi.andarium"',
                 '"PRODUCT_BUNDLE_IDENTIFIER": "com.kelly.trolldroid"')
    replace_once(project, '"ASSETCATALOG_COMPILER_APPICON_NAME": "DuskJade",\n'
                 '        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"',
                 '"ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",\n'
                 '        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"', expected=2)

    icon_set = app / "Andarium/Shared/Assets.xcassets/AppIcon.appiconset"
    icon_set.mkdir(parents=True, exist_ok=True)
    # A local AppIcon.local.png (ignored) replaces the tracked icon.
    local = HERE / "icon/AppIcon.local.png"
    shutil.copyfile(local if local.is_file() else HERE / "icon/AppIcon.png", icon_set / "AppIcon.png")
    (icon_set / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n", encoding="utf-8")

    # The images and the recovery menu. Live/ is a synchronized folder of the
    # device target, so new files join it without a project edit.
    for source in sorted((HERE / "app").glob("*.swift")):
        shutil.copyfile(source, app / "Andarium/Live" / source.name)

    entry = app / "Andarium/Live/AppEntry.swift"
    replace_once(entry,
                 "let systemFolder = bundle.resourceURL?.appendingPathComponent(SystemFolder.name)",
                 "let systemFolder = TrolldroidSlots.systemFolder(TrolldroidSlots.current)\n"
                 "            ?? bundle.resourceURL?.appendingPathComponent(SystemFolder.name)")
    replace_once(entry,
                 'return library.appendingPathComponent("Guest", isDirectory: true)',
                 "return TrolldroidSlots.instance(TrolldroidSlots.current)")

    # The scene opens on the recovery menu; its boot builds the process's
    # model for the chosen image, which AndariumProcess.shared creates lazily.
    scene = app / "Andarium/Shared/AndariumApp.swift"
    replace_once(scene,
                 "    func connect(_ scene: UIWindowScene) {\n"
                 "        guard window == nil else { return }\n",
                 "    func connect(_ scene: UIWindowScene) {\n"
                 "        guard window == nil else { return }\n"
                 "        showRecovery(scene)\n"
                 "    }\n\n"
                 "    func boot(_ scene: UIWindowScene) {\n")
    print(f"trolldroid/apply.py: {root} is now Trolldroid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
