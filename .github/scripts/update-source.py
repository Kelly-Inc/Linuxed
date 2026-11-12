#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Point the Linuxed entry of an AltStore source at a newly built .ipa.

update-source.py SOURCE IPA URL [--seed SEED]

SOURCE is rewritten in place. When it holds no source (empty or not JSON),
SEED, a copy of the source as the site serves it, is the starting point. The
entry is found by its bundle identifier; a missing one is made from the
source's first app, so it keeps that app's developer, tint and screenshots.
"""

import argparse
import datetime
import json
import plistlib
import sys
import zipfile
from pathlib import Path

BUNDLE_ID = "lol.respring.linuxed"
ICON = "https://raw.githubusercontent.com/Kelly-Inc/Linuxed/main/Linuxed/Linuxed/Assets.xcassets/AppIcon.appiconset/AppIcon.png"


def app_version(ipa: Path) -> str:
    with zipfile.ZipFile(ipa) as archive:
        name = next(n for n in archive.namelist()
                    if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/") == 2)
        info = plistlib.loads(archive.read(name))
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        sys.exit(f"update-source.py: the .ipa is {info.get('CFBundleIdentifier')}, not {BUNDLE_ID}")
    return str(info["CFBundleShortVersionString"])


def load(path: Path) -> dict | None:
    try:
        source = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return source if isinstance(source, dict) and isinstance(source.get("apps"), list) else None


def update(source: dict, version: str, url: str, size: int, date: str) -> dict:
    apps = source["apps"]
    entry = next((app for app in apps if app.get("bundleIdentifier") == BUNDLE_ID), None)
    if entry is None:
        entry = {key: value for key, value in (apps[0] if apps else {}).items()
                 if key in ("developerName", "tintColor", "screenshotURLs")}
        entry.update(name="Linuxed", bundleIdentifier=BUNDLE_ID, iconURL=ICON,
                     subtitle="Linux on iOS without JIT",
                     localizedDescription="Linuxed runs a real Linux kernel inside the app.")
        apps.insert(0, entry)
    entry.update(version=version, versionDate=date, downloadURL=url, size=size,
                 versionDescription=entry.get("versionDescription") or f"Linuxed {version}.")
    return source


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("url")
    parser.add_argument("--seed", type=Path)
    args = parser.parse_args()
    source = load(args.source) or (load(args.seed) if args.seed else None)
    if source is None:
        sys.exit("update-source.py: neither the source nor the seed is an AltStore source")
    date = datetime.date.today().isoformat()
    update(source, app_version(args.ipa), args.url, args.ipa.stat().st_size, date)
    args.source.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
