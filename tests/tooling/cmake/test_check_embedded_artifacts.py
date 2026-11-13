#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""scripts/check-embedded-artifacts.py refuses a kernel bundle behind its commit.

Each case builds a synthetic Git repository holding the kernel descriptor,
metadata, series and fragments, and an application whose runtime framework
carries a kernel banner and configuration, then changes one thing.
"""

from __future__ import annotations

__import__("sys").dont_write_bytecode = True

import gzip
import importlib.util
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[3]
SCRIPT = REPOSITORY / "scripts/check-embedded-artifacts.py"

KERNEL_ID = "20261201-6.18.99-ks99"
KERNEL_RELEASE = "6.18.99-gfeedface0000"
TREE = "a" * 40
OTHER_TREE = "b" * 40
FRAMEWORK = "KRuntime_6_18_4K"
KERNEL_DESCRIPTOR = "kernel/mainline-6.18/artifacts/accepted-4k.env"
METADATA = "kernel/mainline-6.18/patches/metadata.env"
FRAGMENT = "kernel/mainline-6.18/config/mainline.fragment"
CONFIG = "CONFIG_UML=y\nCONFIG_MODULES=n\nCONFIG_EXT4_FS=y\n# CONFIG_NFS_FS is not set\nCONFIG_HZ=100\n"


def git(repo: Path, *arguments: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *arguments],
        check=True, stdin=subprocess.DEVNULL, capture_output=True, text=True,
    ).stdout.strip()


def write(repo: Path, relative: str, text: str) -> None:
    path = repo / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def commit(repo: Path, message: str) -> str:
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", message)
    return git(repo, "rev-parse", "HEAD")


def macho(sections: dict) -> bytes:
    """A thin arm64 Mach-O whose __TEXT segment holds the given sections."""
    names = list(sections)
    command_size = 72 + 80 * len(names)
    offset = 32 + command_size
    entries = b""
    payload = b""
    for name in names:
        data = sections[name]
        entries += (
            name.encode().ljust(16, b"\0") + b"__TEXT".ljust(16, b"\0")
            + struct.pack("<QQIIIIIIII", 0, len(data), offset + len(payload), 0, 0, 0, 0, 0, 0, 0)
        )
        payload += data
    segment = (
        struct.pack("<II", 0x19, command_size) + b"__TEXT".ljust(16, b"\0")
        + struct.pack("<QQQQIIII", 0, offset + len(payload), 0, offset + len(payload), 7, 5, len(names), 0)
    )
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 6, 1, command_size, 0, 0)
    return header + segment + entries + payload


# build-kernel.sh still names the builder linuxed until the next kernel.
NEUTRAL_BUILDER = "linuxed@linuxed"


def kernel_image(
    release: str = KERNEL_RELEASE, config: str = CONFIG,
    builder: str = NEUTRAL_BUILDER, proc_builder: str = NEUTRAL_BUILDER,
) -> bytes:
    """A kernel image with the banner and the /proc/version format, which both name the builder."""
    return (
        b"\x7fELF" + b"\0" * 64
        + f"Linux version {release} ({builder}) (clang) #1 SMP\n".encode()
        + b"\0" * 8 + f"%s version %s ({proc_builder}) (clang) %s\n".encode()
        + b"\0" * 32 + b"IKCFG_ST" + gzip.compress(config.encode()) + b"IKCFG_ED" + b"\0" * 16
    )



class Fixture:
    """A repository whose kernel bundle is current, and an app that embeds it."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.repo = root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", ".")
        write(self.repo, "kernel/common/patches/0001-one.patch", "one\n")
        write(self.repo, "kernel/mainline-6.18/patches/series/0001-two.patch", "two\n")
        write(self.repo, METADATA, f"UML_KERNEL_FINAL_TREE='{TREE}'\n")
        write(self.repo, "kernel/common/config/darwin-uml.fragment", "CONFIG_UML=y\nCONFIG_MODULES=n\n")
        write(self.repo, FRAGMENT, "CONFIG_EXT4_FS=y\n# CONFIG_NFS_FS is not set\n")
        self.first = commit(self.repo, "base")
        self.set_descriptor()
        self.app = self.package()

    def set_descriptor(self, kernel_tree: str = TREE) -> None:
        write(
            self.repo, KERNEL_DESCRIPTOR,
            f"UML_KERNEL_ARTIFACT_RELEASE_ID='{KERNEL_ID}'\n"
            f"UML_KERNEL_ARTIFACT_RELEASE='{KERNEL_RELEASE}'\n"
            f"UML_KERNEL_ARTIFACT_FINAL_TREE='{kernel_tree}'\n")
        commit(self.repo, "accept the kernel")

    def package(self, release: str = KERNEL_RELEASE, config: str = CONFIG, **builders: str) -> Path:
        app = self.root / "Linuxed.app"
        shutil.rmtree(app, ignore_errors=True)
        framework = app / "Frameworks" / f"{FRAMEWORK}.framework"
        framework.mkdir(parents=True)
        (framework / FRAMEWORK).write_bytes(macho({"__uml_elf": kernel_image(release, config, **builders)}))
        return app

    def run(self, decision: str | None = None, app: bool = True):
        environment = {key: value for key, value in os.environ.items() if key != "PENDING_INPUTS_DECISION"}
        if decision is not None:
            environment["PENDING_INPUTS_DECISION"] = decision
        command = [sys.executable, "-B", str(SCRIPT), "--repository", str(self.repo), "--kernel", "arm64"]
        if app:
            command += ["--app", str(self.app)]
        return subprocess.run(command, env=environment, check=False, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=120)


class CheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.fixture = Fixture(self.root)
        self.repo = self.fixture.repo

    def passes(self, result) -> None:
        self.assertEqual(result.returncode, 0, result.stderr)

    def fails(self, result, *needles: str) -> None:
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for needle in needles:
            self.assertIn(needle, result.stderr)

    def test_current_kernel_passes(self) -> None:
        self.passes(self.fixture.run())

    def test_a_dirty_fragment_fails_and_no_decision_covers_it(self) -> None:
        write(self.repo, "kernel/common/config/darwin-uml.fragment", "CONFIG_UML=n\n")
        self.fails(self.fixture.run(decision=KERNEL_ID), "darwin-uml.fragment")

    def test_a_directory_that_is_not_a_work_tree_fails(self) -> None:
        plain = self.root / "plain"
        plain.mkdir()
        result = subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "--repository", str(plain), "--kernel", "arm64"],
            capture_output=True, text=True, check=False, stdin=subprocess.DEVNULL, timeout=60)
        self.fails(result, "not a Git work tree")

    def test_a_kernel_behind_its_series_names_the_changed_paths(self) -> None:
        write(self.repo, "kernel/common/patches/0002-three.patch", "three\n")
        write(self.repo, METADATA, f"UML_KERNEL_FINAL_TREE='{OTHER_TREE}'\n")
        commit(self.repo, "kernel: add a shared topic")
        self.fails(self.fixture.run(), KERNEL_ID, "behind its patch series", METADATA,
                   "0002-three.patch", "kernel: add a shared topic")
        self.assertEqual(self.fixture.run(decision="other").returncode, 1)
        self.passes(self.fixture.run(decision=KERNEL_ID))

    def test_a_kernel_tree_missing_from_the_history_is_said_so(self) -> None:
        self.fixture.set_descriptor(kernel_tree="f" * 40)
        self.fails(self.fixture.run(app=False), "behind its patch series", "is not in the last")

    def test_a_packaged_kernel_that_is_not_the_accepted_one_fails_whatever_the_decision(self) -> None:
        self.fixture.app = self.fixture.package(release="6.18.98-gdeadbeef0000")
        self.fails(self.fixture.run(decision=KERNEL_ID),
                   "6.18.98-gdeadbeef0000", KERNEL_RELEASE, "package the frameworks")

    def test_a_packaged_kernel_built_as_another_user_or_host_fails(self) -> None:
        cases = {
            "banner user": {"builder": "qzxuser@linuxed"},
            "banner host": {"builder": "linuxed@qzxhost"},
            "proc format": {"proc_builder": "qzxuser@qzxhost"},
        }
        for label, builders in cases.items():
            with self.subTest(label):
                self.fixture.app = self.fixture.package(**builders)
                result = self.fixture.run(decision=KERNEL_ID)
                self.fails(result, NEUTRAL_BUILDER, "build-kernel.sh")
                self.assertNotIn("qzx", result.stdout + result.stderr)

    def test_a_missing_runtime_framework_fails(self) -> None:
        shutil.rmtree(self.fixture.app / "Frameworks")
        self.fails(self.fixture.run(decision=KERNEL_ID), f"embeds no {FRAMEWORK}")

    def test_a_packaged_configuration_behind_its_fragments_is_pending(self) -> None:
        self.fixture.app = self.fixture.package(config=CONFIG.replace("CONFIG_EXT4_FS=y", "# CONFIG_EXT4_FS is not set"))
        write(self.repo, FRAGMENT, "CONFIG_EXT4_FS=y\n# CONFIG_NFS_FS is not set\nCONFIG_HZ=250\n")
        commit(self.repo, "config: tick at 250 Hz")
        self.fails(self.fixture.run(), "configuration is behind its fragments", "CONFIG_EXT4_FS",
                   "CONFIG_HZ: ", "requests 250", "config: tick at 250 Hz")
        self.passes(self.fixture.run(decision=KERNEL_ID))

    def test_the_last_fragment_that_names_a_symbol_owns_it(self) -> None:
        write(self.repo, FRAGMENT, "CONFIG_MODULES=y\nCONFIG_EXT4_FS=y\n# CONFIG_NFS_FS is not set\n")
        commit(self.repo, "config: product overrides the shared policy")
        self.fails(self.fixture.run(), "CONFIG_MODULES", "mainline.fragment requests y")

    def test_a_kernel_without_a_configuration_fails(self) -> None:
        image = b"\x7fELF" + f"Linux version {KERNEL_RELEASE} ({NEUTRAL_BUILDER}) #1\n".encode()
        (self.fixture.app / "Frameworks" / f"{FRAMEWORK}.framework" / FRAMEWORK).write_bytes(macho({"__uml_elf": image}))
        self.fails(self.fixture.run(decision=KERNEL_ID), "carries no configuration")

    def test_a_runtime_without_a_kernel_image_fails(self) -> None:
        (self.fixture.app / "Frameworks" / f"{FRAMEWORK}.framework" / FRAMEWORK).write_bytes(macho({"__other": b"x"}))
        self.fails(self.fixture.run(decision=KERNEL_ID), "carries no __uml_elf")

    def test_naming_no_artifact_is_refused(self) -> None:
        result = subprocess.run([sys.executable, "-B", str(SCRIPT), "--repository", str(self.repo)],
                                capture_output=True, text=True, check=False, stdin=subprocess.DEVNULL, timeout=60)
        self.assertEqual(result.returncode, 2)


class ConfigParityTests(unittest.TestCase):
    """The symbol check agrees with the kernel build's own (config-fragments.sh)."""

    CASES = (
        ("all symbols match", ["CONFIG_A=y\n# CONFIG_B is not set\nCONFIG_N=4096\nCONFIG_S=\"x\"\n"],
         "CONFIG_A=y\n# CONFIG_B is not set\nCONFIG_N=4096\nCONFIG_S=\"x\"\n"),
        ("a requested symbol is absent", ["CONFIG_A=y\n"], "CONFIG_Z=y\n"),
        ("a disabled symbol is absent", ["# CONFIG_B is not set\n"], "CONFIG_Z=y\n"),
        ("a disabled symbol is enabled", ["# CONFIG_B is not set\n"], "CONFIG_B=y\n"),
        ("the last fragment owns a symbol", ["CONFIG_A=y\n", "# CONFIG_A is not set\n"], "# CONFIG_A is not set\n"),
        ("the last fragment loses to the build", ["# CONFIG_A is not set\n", "CONFIG_A=y\n"], "# CONFIG_A is not set\n"),
        ("a value differs", ["CONFIG_N=4096\n"], "CONFIG_N=1024\n"),
        ("a string differs", ["CONFIG_S=\"x\"\n"], "CONFIG_S=\"y\"\n"),
        ("comments and blanks are ignored", ["# a comment\n\nCONFIG_A=y\n"], "CONFIG_A=y\n"),
    )

    def test_verdicts_agree(self) -> None:
        spec = importlib.util.spec_from_file_location("check_embedded_artifacts", SCRIPT)
        checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(checker)
        helper = REPOSITORY / "kernel/common/tooling/config-fragments.sh"
        for label, fragments, config in self.CASES:
            with self.subTest(label), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch)
                names = []
                for index, text in enumerate(fragments):
                    write(root, f"f{index}.fragment", text)
                    names.append(f"f{index}.fragment")
                write(root, "config", config)
                shell = subprocess.run(
                    ["sh", "-c", f". {helper}; uml_kernel_config_verify \"$@\"", "sh", str(root / "config"),
                     *[str(root / name) for name in names]],
                    capture_output=True, text=True, check=False, stdin=subprocess.DEVNULL)
                problems = checker.config_mismatches(root, {"fragments": names}, config)
                self.assertEqual(shell.returncode == 0, not problems, (shell.stderr, problems))


if __name__ == "__main__":
    unittest.main(verbosity=2)
