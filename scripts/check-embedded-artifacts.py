#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check that the artifacts an application embeds carry the commit being built.

An accepted artifact is the only way a change to its inputs reaches users, so a
release build that embeds one older than the inputs on its commit ships
without that change (AGENTS.md, "Release builds"). The check compares the
checkout it runs in, a Git work tree, with the accepted descriptors and with
what is staged and packaged; it reads no kernel checkout and runs no build.

Kernel bundle (--kernel arm64|x86_64):
  - the tracked final tree of the line (UML_KERNEL_FINAL_TREE) equals the one
    the accepted descriptor records, which is every patch of the series;
  - with --app, the kernel in the packaged runtime framework is the kernel the
    descriptor names (the release in its Linux banner), its banner names the
    neutral build user and host kernarium@kernarium, and its embedded
    configuration (CONFIG_IKCONFIG) holds every symbol the tracked fragments
    request, as the build's own check does. The bundle manifest records no
    configuration identity, so a symbol removed from a fragment, which falls
    back to its default, is the one change this cannot see.

The inputs, the descriptors and the files the checks read must be clean in the
work tree: an uncommitted change would be archived without a commit that
records it.

A stale or unverifiable artifact (the two findings below "pending") stops the
build unless the user has decided to ship it as it is: PENDING_INPUTS_DECISION,
a build setting or an environment value, names the release IDs (space or comma
separated) of the artifacts whose pending changes that decision covers. A
decision that names another release ID, or the ID of a release that is current,
covers nothing, so it cannot carry over to a later release. A dirty input, a
staged or packaged artifact that is not the accepted one and a kernel that is
not the descriptor's are never covered.

Run it before archiving a Linuxed release.
"""

from __future__ import annotations

__import__("sys").dont_write_bytecode = True

import argparse
import gzip
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE / "kernel/common/artifacts"))
import contract_checks  # noqa: E402

DECISION_ENV = "PENDING_INPUTS_DECISION"
ELF_SECTION = ("__TEXT", "__uml_elf")
# The build user and host build-kernel.sh gives every kernel; any other pair in
# a banner is the builder's own account and machine.
NEUTRAL_BUILDER = "kernarium@kernarium"
HISTORY_LIMIT = 400
SHOWN_COMMITS = 10

MAINLINE = "kernel/mainline-6.18"
SHARED_CONFIG = "kernel/common/config/darwin-uml.fragment"
KERNELS = {
    "arm64": {
        "descriptor": f"{MAINLINE}/artifacts/accepted-4k.env",
        "metadata": f"{MAINLINE}/patches/metadata.env",
        "series": ("kernel/common/patches", f"{MAINLINE}/patches/series"),
        "fragments": (SHARED_CONFIG, f"{MAINLINE}/config/mainline.fragment"),
        "framework": "KRuntime_6_18_4K",
    },
    "x86_64": {
        "descriptor": f"{MAINLINE}/slices/x86_64/artifacts/accepted-4k.env",
        "metadata": f"{MAINLINE}/slices/x86_64/patches/metadata.env",
        "series": (
            "kernel/common/patches",
            f"{MAINLINE}/patches/series",
            f"{MAINLINE}/slices/x86_64/patches/series",
        ),
        "fragments": (
            SHARED_CONFIG,
            f"{MAINLINE}/config/mainline.fragment",
            f"{MAINLINE}/slices/x86_64/config/userspace.fragment",
        ),
    },
}


class Report:
    """Findings of one run: errors that stand, and pending changes per artifact."""

    def __init__(self, decisions):
        self.decisions = decisions
        self.errors = []
        self.pending = {}
        self.notes = []

    def error(self, title, *details):
        self.errors.append((title, details))

    def pend(self, artifact_id, title, *details):
        self.pending.setdefault(artifact_id, []).append((title, details))

    def note(self, line):
        self.notes.append(line)

    def finish(self):
        warnings = []
        covered = set()
        for artifact_id, findings in sorted(self.pending.items()):
            if artifact_id in self.decisions:
                covered.add(artifact_id)
                for title, details in findings:
                    warnings.append((f"{title}; the archive will not carry it", details))
                continue
            for title, details in findings:
                self.errors.append((
                    title,
                    details + (
                        "build and accept a new artifact first; shipping this one "
                        "as it is waits for the user's decision "
                        f"({DECISION_ENV}={artifact_id})",
                    ),
                ))
        for line in self.notes:
            print(f"check-embedded-artifacts: {line}")
        for title, details in warnings:
            emit("warning", title, details)
        for unused in sorted(self.decisions - covered):
            emit("warning", f"{DECISION_ENV} names {unused}, which has no pending change; "
                 "it covers nothing", ())
        for title, details in self.errors:
            emit("error", title, details)
        return 1 if self.errors else 0


def emit(level, title, details):
    print(f"{level}: {title}", file=sys.stderr)
    for line in details:
        print(f"    {line}", file=sys.stderr)


def short(object_id):
    return object_id[:10] if object_id else "absent"


class InputError(ValueError):
    pass


OBJECT_ID_RE = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")


def git(repo, *arguments, stdin=None):
    result = subprocess.run(["git", "-C", str(repo), *arguments], check=False, input=stdin,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise InputError(f"git {arguments[0]} failed in {repo}: "
                         f"{result.stderr.decode('utf-8', 'replace').strip()}")
    return result.stdout


def git_text(repo, *arguments, stdin=None):
    return git(repo, *arguments, stdin=stdin).decode("utf-8", "replace")


def object_ids_at(repo, paths, revision="HEAD"):
    """Object ID of each path at a revision, None where the revision has none."""
    if not paths:
        return {}
    request = "".join(f"{revision}:{path}\n" for path in paths).encode("utf-8")
    answer = git_text(repo, "cat-file", "--batch-check", stdin=request).splitlines()
    if len(answer) != len(paths):
        raise InputError("git cat-file answered a different number of paths")
    result = {}
    for path, line in zip(paths, answer):
        fields = line.split(" ")
        found = len(fields) == 3 and OBJECT_ID_RE.fullmatch(fields[0])
        result[path] = fields[0] if found else None
    return result


def dirty_paths(repo, paths):
    """Paths below the given ones with a change the work tree has not committed."""
    listing = git(
        repo, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", *paths
    ).decode("utf-8", "replace")
    fields = listing.split("\0")
    found = set()
    index = 0
    while index < len(fields):
        entry = fields[index]
        index += 1
        if len(entry) < 4:
            continue
        found.add(entry[3:])
        if entry[0] in "RC":
            index += 1  # the rename's origin
    return sorted(found)


def commits_touching(repo, path, newest_first_limit=HISTORY_LIMIT):
    """(full hash, short hash, subject) of the commits that changed a path, newest first."""
    out = git_text(repo, "log", f"-n{newest_first_limit}", "--format=%H\t%h\t%s", "HEAD", "--", path)
    return [tuple(line.split("\t", 2)) for line in out.splitlines() if line.count("\t") == 2]


def commits_since_object(repo, path, recorded):
    """Commits that changed a path after it held the recorded object, or None if
    no commit in the history held it."""
    commits = commits_touching(repo, path)
    ids = []
    if commits:
        request = "".join(f"{full}:{path}\n" for full, _, _ in commits).encode("utf-8")
        for line in git_text(repo, "cat-file", "--batch-check", stdin=request).splitlines():
            fields = line.split(" ")
            ids.append(fields[0] if len(fields) == 3 else None)
    for index, object_id in enumerate(ids):
        if object_id == recorded:
            return commits[:index]
    return None


def commit_lines(commits):
    lines = [f"{short_hash} {subject}" for _, short_hash, subject in commits[:SHOWN_COMMITS]]
    if len(commits) > SHOWN_COMMITS:
        lines.append(f"... and {len(commits) - SHOWN_COMMITS} more")
    return lines


def read_json(path):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ValueError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{path} is not a JSON object")
    return value


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 22), b""):
            digest.update(block)
    return digest.hexdigest()


def descriptor_of(repo, relative):
    return contract_checks.parse_assignments(repo / relative)


# ----------------------------------------------------------------- kernel --


def requested_symbols(repo, fragments):
    """symbol -> (wanted value, fragment); the last fragment naming a symbol wins."""
    wanted = {}
    for relative in fragments:
        for raw in (repo / relative).read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            match = re.fullmatch(r"(CONFIG_[A-Za-z0-9_]+)=(.*)", line)
            if match:
                wanted[match.group(1)] = (match.group(2), relative)
                continue
            match = re.fullmatch(r"# (CONFIG_[A-Za-z0-9_]+) is not set", line)
            if match:
                wanted[match.group(1)] = ("n", relative)
    return wanted


def resolved_config(text):
    built = {}
    for raw in text.splitlines():
        match = re.match(r"(CONFIG_[A-Za-z0-9_]+)=(.*)", raw)
        if match:
            built[match.group(1)] = match.group(2)
            continue
        match = re.fullmatch(r"# (CONFIG_[A-Za-z0-9_]+) is not set", raw)
        if match:
            built[match.group(1)] = "n"
    return built


def config_mismatches(repo, kernel, config_text):
    """Lines naming each symbol a fragment requests that the configuration lacks.

    Mirrors uml_kernel_config_verify in kernel/common/tooling/config-fragments.sh.
    """
    built = resolved_config(config_text)
    problems = []
    for symbol, (wanted, fragment) in sorted(requested_symbols(repo, kernel["fragments"]).items()):
        got = built.get(symbol, "n")
        if got != wanted:
            problems.append(
                f"{symbol}: {fragment} requests {wanted}, the packaged kernel has "
                f"{got if symbol in built else 'absent'}")
    for key, wanted in (("required", "y"), ("forbidden", "n")):
        if key not in kernel:
            continue
        for raw in (repo / kernel[key]).read_text(encoding="utf-8").splitlines():
            symbol = raw.strip()
            if symbol and not symbol.startswith("#") and built.get(symbol, "n") != wanted:
                problems.append(
                    f"{symbol}: {kernel[key]} requires {wanted}, the packaged kernel has "
                    f"{built.get(symbol, 'absent')}")
    return problems


def thin_offset(data):
    if len(data) < 8:
        return None
    if struct.unpack_from(">I", data, 0)[0] == 0xCAFEBABE:
        for index in range(min(struct.unpack_from(">I", data, 4)[0], 16)):
            cpu, _, offset, _, _ = struct.unpack_from(">IIIII", data, 8 + 20 * index)
            if cpu == 0x0100000C:
                return offset
        return None
    return 0 if struct.unpack_from("<I", data, 0)[0] == 0xFEEDFACF else None


def macho_section(path, wanted):
    """The bytes of one section of an arm64 Mach-O file, or None."""
    data = path.read_bytes()
    base = thin_offset(data[:4096])
    if base is None:
        return None
    count = struct.unpack_from("<I", data, base + 16)[0]
    position = base + 32
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, position)
        if command == 0x19:  # LC_SEGMENT_64
            sections = struct.unpack_from("<I", data, position + 64)[0]
            entry = position + 72
            for _ in range(sections):
                name = data[entry:entry + 16].rstrip(b"\0").decode("ascii", "replace")
                segment = data[entry + 16:entry + 32].rstrip(b"\0").decode("ascii", "replace")
                length, offset = struct.unpack_from("<QI", data, entry + 40)
                if (segment, name) == wanted:
                    return data[base + offset:base + offset + length]
                entry += 80
        position += size
    return None


def kernel_banner_releases(image):
    return sorted({
        match.group(1).decode("ascii")
        for match in re.finditer(rb"Linux version ([0-9][0-9A-Za-z._+~-]*) \(", image)
    })


def kernel_banner_builders(image):
    """The user@host pairs of the kernel's Linux banner and /proc/version format."""
    return sorted({
        match.group(1).decode("ascii", "replace")
        for match in re.finditer(
            rb"(?:Linux version [0-9][0-9A-Za-z._+~-]*|%s version %s) \(([^()]*)\)", image)
    })


def embedded_config(image):
    start = image.find(b"IKCFG_ST\x1f\x8b")
    end = image.find(b"IKCFG_ED", start + 8) if start >= 0 else -1
    if start < 0 or end < 0:
        return None
    try:
        return gzip.decompress(image[start + 8:end]).decode("utf-8", "replace")
    except (OSError, EOFError):
        return None


def last_commit(repo, path):
    out = git_text(repo, "log", "-n1", "--format=%H", "HEAD", "--", path).strip()
    return out or None


def check_kernel(repo, report, name, app):
    kernel = KERNELS[name]
    try:
        descriptor = descriptor_of(repo, kernel["descriptor"])
        metadata = contract_checks.parse_assignments(repo / kernel["metadata"])
        release_id = descriptor["UML_KERNEL_ARTIFACT_RELEASE_ID"]
        accepted_tree = descriptor["UML_KERNEL_ARTIFACT_FINAL_TREE"]
        accepted_release = descriptor["UML_KERNEL_ARTIFACT_RELEASE"]
        tracked_tree = metadata["UML_KERNEL_FINAL_TREE"]
    except (ValueError, KeyError) as error:
        report.error(f"the {name} kernel descriptor or its tracked metadata is unreadable", str(error))
        return
    label = f"the {name} kernel bundle {release_id}"

    if tracked_tree != accepted_tree:
        details = [
            f"{kernel['metadata']}: final tree {short(tracked_tree)} here, "
            f"{short(accepted_tree)} accepted",
        ]
        since = None
        for full, short_hash, _ in commits_touching(repo, kernel["metadata"]):
            blob = git_text(repo, "show", f"{full}:{kernel['metadata']}")
            if re.search(rf"^UML_KERNEL_FINAL_TREE='{accepted_tree}'$", blob, re.M):
                since = full
                break
        if since is None:
            details.append("the accepted tree is not in the last "
                           f"{HISTORY_LIMIT} changes of the metadata's history")
        else:
            paths = list(kernel["series"]) + [kernel["metadata"]]
            changed = git_text(repo, "diff", "--name-only", f"{since}..HEAD", "--", *paths).split()
            details.append("changed series paths: " + ", ".join(changed[:12])
                           + (f" and {len(changed) - 12} more" if len(changed) > 12 else ""))
            log = git_text(repo, "log", "--format=%H\t%h\t%s", f"{since}..HEAD", "--", *paths)
            commits = [tuple(line.split("\t", 2)) for line in log.splitlines()]
            details.extend(commit_lines(commits))
        report.pend(release_id, f"{label} is behind its patch series", *details)
    else:
        report.note(f"{label}: its final tree is the tracked one")

    if app is None or "framework" not in kernel:
        return
    framework = app / "Frameworks" / f"{kernel['framework']}.framework" / kernel["framework"]
    if not framework.is_file():
        report.error(f"the application embeds no {kernel['framework']} for {label}", str(framework))
        return
    image = macho_section(framework, ELF_SECTION)
    if image is None:
        report.error(f"{kernel['framework']} carries no {ELF_SECTION[1]} kernel image", str(framework))
        return
    releases = kernel_banner_releases(image)
    if releases != [accepted_release]:
        report.error(
            f"the kernel in {kernel['framework']} is not the one {label} accepts",
            f"packaged: {', '.join(releases) or 'no Linux banner'}; accepted: {accepted_release}; "
            "package the frameworks from the accepted bundle in the same run",
        )
        return
    # The pairs found are personal values, so the message never repeats them.
    if kernel_banner_builders(image) != [NEUTRAL_BUILDER]:
        report.error(
            f"the kernel in {kernel['framework']} does not name {NEUTRAL_BUILDER} as its build user and host",
            "build the bundle with build-kernel.sh and package the frameworks from it",
        )
        return
    config = embedded_config(image)
    if config is None:
        report.error(
            f"the kernel in {kernel['framework']} carries no configuration to check",
            "CONFIG_IKCONFIG embeds it",
        )
        return
    problems = config_mismatches(repo, kernel, config)
    if problems:
        paths = list(kernel["fragments"]) + [kernel[key] for key in ("required", "forbidden") if key in kernel]
        accepted_at = last_commit(repo, kernel["descriptor"])
        details = problems[:12]
        if len(problems) > 12:
            details.append(f"... and {len(problems) - 12} more")
        if accepted_at is not None:
            log = git_text(repo, "log", "--format=%H\t%h\t%s", f"{accepted_at}..HEAD", "--", *paths)
            commits = [tuple(line.split("\t", 2)) for line in log.splitlines()]
            if commits:
                details.append("configuration inputs changed since the descriptor was accepted:")
                details.extend(f"    {line}" for line in commit_lines(commits))
        report.pend(
            release_id,
            f"the packaged {name} kernel's configuration is behind its fragments",
            *details,
        )
    else:
        report.note(f"{label}: the packaged kernel holds every configuration symbol requested")


# ------------------------------------------------------------------- main --


def parse_decisions(text):
    return {item for item in re.split(r"[\s,]+", text or "") if item}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repository", type=Path, default=HERE,
                        help="the Git work tree being built (default: this one)")
    parser.add_argument("--app", type=Path,
                        help="the built application, whose packaged runtimes are checked")
    parser.add_argument("--kernel", action="append", default=[], choices=sorted(KERNELS),
                        help="check an accepted kernel bundle (repeatable)")
    parser.add_argument("--decision", default=None,
                        help=f"the release IDs the user decided to ship as they are "
                             f"(default: ${DECISION_ENV})")
    options = parser.parse_args(argv)
    if not options.kernel:
        parser.error("name an artifact: --kernel")

    repo = options.repository.resolve()
    decisions = parse_decisions(
        options.decision if options.decision is not None else os.environ.get(DECISION_ENV))
    report = Report(decisions)
    try:
        git(repo, "rev-parse", "--git-dir")
    except InputError as error:
        report.error("this is not a Git work tree, so there is no commit to compare", str(error))
        return report.finish()

    covered = []
    for name in options.kernel:
        kernel = KERNELS[name]
        covered += [kernel["descriptor"], kernel["metadata"], *kernel["series"], *kernel["fragments"]]
        covered += [kernel[key] for key in ("required", "forbidden") if key in kernel]
    try:
        dirty = dirty_paths(repo, sorted(set(covered)))
    except InputError as error:
        report.error("cannot read the work tree's status", str(error))
        dirty = []
    if dirty:
        report.error(
            f"{len(dirty)} path{'s' if len(dirty) != 1 else ''} the artifacts are checked against "
            "have uncommitted changes, which the archive would carry without a commit that records them",
            *dirty[:20],
        )

    for name in options.kernel:
        check_kernel(repo, report, name, options.app)
    return report.finish()


if __name__ == "__main__":
    sys.exit(main())
