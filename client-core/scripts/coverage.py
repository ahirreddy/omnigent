#!/usr/bin/env python3
"""Line coverage of the Rust core from its own tests, by crate.

Usage: coverage.py [--no-test] [--jobs N] [--top N] [--excluded]

Builds and runs the workspace's tests with coverage on, under target/coverage so the normal build
is left alone, using the LLVM tools that match rustc (rustup's `llvm-tools` component). Prints each
crate's line coverage and writes the missed line ranges to target/coverage/uncovered.txt.

Test files and a file's trailing `#[cfg(test)]` module don't count. Code no test can reach goes
between `// coverage:off <why no test can reach it>` and `// coverage:on`; `--excluded` lists them.

Exits non-zero if a test fails or a crate has no measured coverage.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CRATES = ROOT / "crates"
OUTPUT = ROOT / "target" / "coverage"
PROFILES = OUTPUT / "profraw"
PROFDATA = OUTPUT / "merged.profdata"
LCOV = OUTPUT / "coverage.lcov"
UNCOVERED = OUTPUT / "uncovered.txt"

# uniffi-bindgen is a one-line binary that hands off to uniffi's CLI: nothing of ours to test.
EXCLUDED_CRATES = {"uniffi-bindgen"}

# Test files, by name and by directory.
TEST_SOURCES = re.compile(r"(_tests?\.rs$|/tests?\.rs$|/tests/|/testing\.rs$|/test_support\.rs$)")

# Dependencies, the standard library and generated build output.
IGNORED_SOURCES = r"(/\.cargo/|/\.rustup/|/rustc/|target/coverage)"

COVERAGE_OFF = re.compile(r"^\s*// coverage:off(?:\s+(.*\S))?\s*$")
COVERAGE_ON = re.compile(r"^\s*// coverage:on\s*$")
TEST_CONFIG = "#[cfg(test)]"
INLINE_MODULE = re.compile(r"(pub(\(crate\))? )?mod \w+ \{")


def line_ranges(lines):
    """Compresses sorted line numbers to `a-b` ranges."""
    ranges = []
    for line in lines:
        if ranges and ranges[-1][1] == line - 1:
            ranges[-1][1] = line
        else:
            ranges.append([line, line])
    return [f"{start}-{end}" if start != end else str(start) for start, end in ranges]


def parse_lcov(text):
    """Per-file `{line: hits}` from an lcov export; any hit in any test binary covers a line."""
    files = {}
    current = None
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith("SF:"):
            current = files.setdefault(line[3:], {})
        elif line.startswith("DA:"):
            number, count = line[3:].split(",")[:2]
            current[int(number)] = max(current.get(int(number), 0), int(count))
    return files


def test_module_start(source):
    """The 1-based line of the `#[cfg(test)]` opening an inline test module, else None."""
    lines = source.split("\n")
    for index, text in enumerate(lines):
        if text.strip() != TEST_CONFIG:
            continue
        cursor = index + 1
        depth = 0
        # Step past further attributes, which may span lines.
        while cursor < len(lines):
            stripped = lines[cursor].strip()
            if depth == 0 and not stripped.startswith("#["):
                break
            depth += stripped.count("(") - stripped.count(")")
            cursor += 1
        if cursor < len(lines) and INLINE_MODULE.match(lines[cursor].strip()):
            return index + 1
    return None


def excluded_lines(source):
    """Lines between coverage markers, and `(start, end, reason)` for each marked range."""
    excluded, reasons = set(), []
    open_from = reason = None
    for number, text in enumerate(source.splitlines(), start=1):
        off = COVERAGE_OFF.match(text)
        if off:
            if open_from is not None:
                raise ValueError(f"line {number}: coverage:off inside the one at {open_from}")
            if not off.group(1):
                raise ValueError(f"line {number}: coverage:off must say why no test reaches this")
            open_from, reason = number, off.group(1)
        elif COVERAGE_ON.match(text):
            if open_from is None:
                raise ValueError(f"line {number}: coverage:on without coverage:off")
            excluded.update(range(open_from, number + 1))
            reasons.append((open_from, number, reason))
            open_from = None
    if open_from is not None:
        raise ValueError(f"line {open_from}: coverage:off without coverage:on")
    return excluded, reasons


def counted_lines(data, source):
    """`(kept, reasons)`: the `{line: hits}` that count as product code, and the marker reasons."""
    limit = test_module_start(source)
    excluded, reasons = excluded_lines(source)
    kept = {
        number: hits
        for number, hits in data.items()
        if (limit is None or number < limit) and number not in excluded
    }
    return kept, reasons


def relative_source(path):
    """`crate/src/file.rs` for a file in this workspace's crates, else None."""
    marker = "client-core/crates/"
    index = path.find(marker)
    return path[index + len(marker) :] if index >= 0 else None


def summarize(files, read_source=None):
    """Per-file `(relative, kept, reasons)` for the counted files in an lcov export."""
    read_source = read_source or (lambda path: Path(path).read_text(errors="replace"))
    rows = []
    for path, data in files.items():
        relative = relative_source(path)
        if relative is None or TEST_SOURCES.search(path):
            continue
        if relative.split("/")[0] in EXCLUDED_CRATES:
            continue
        try:
            kept, reasons = counted_lines(data, read_source(path))
        except ValueError as error:
            raise ValueError(f"{relative}: {error}") from error
        rows.append((relative, kept, reasons))
    return rows


def crate_totals(rows):
    """`{crate: (lines, missed)}` over the summarized files."""
    totals = {}
    for relative, kept, _reasons in rows:
        lines, missed = totals.get(relative.split("/")[0], (0, 0))
        totals[relative.split("/")[0]] = (
            lines + len(kept),
            missed + sum(1 for hits in kept.values() if hits == 0),
        )
    return totals


def unmeasured_crates(totals, expected):
    """Expected crates with no measured lines, or with lines no test reached at all."""
    return sorted(
        crate
        for crate in expected
        if crate not in totals or totals[crate][0] == 0 or totals[crate][0] == totals[crate][1]
    )


def uncovered_listing(rows):
    """Lines of the uncovered report, worst file first."""
    listing = []
    for relative, kept, _reasons in sorted(
        rows, key=lambda row: -sum(1 for hits in row[1].values() if hits == 0)
    ):
        missing = sorted(number for number, hits in kept.items() if hits == 0)
        if missing:
            ranges = ",".join(line_ranges(missing))
            listing.append(f"{len(missing):5}/{len(kept):5} {relative}: {ranges}")
    return listing


def percent(lines, missed):
    return 100 * (lines - missed) / max(lines, 1)


def print_totals(totals):
    """One line per crate, then the total."""
    all_lines = sum(lines for lines, _missed in totals.values())
    all_missed = sum(missed for _lines, missed in totals.values())
    for crate, (lines, missed) in sorted(totals.items()):
        print(f"{crate:24} {lines:7} lines {missed:6} missed {percent(lines, missed):7.2f}%")
    print(
        f"{'TOTAL':24} {all_lines:7} lines {all_missed:6} missed "
        f"{percent(all_lines, all_missed):7.2f}%"
    )


def workspace_crates():
    """The crates that must report coverage."""
    return {
        path.name
        for path in CRATES.iterdir()
        if (path / "Cargo.toml").exists() and path.name not in EXCLUDED_CRATES
    }


def host_triple():
    host_line = subprocess.check_output(["rustc", "-vV"], cwd=ROOT, text=True)
    return re.search(r"^host: (.+)$", host_line, re.MULTILINE).group(1)


def llvm_tool(name):
    """The rustup `llvm-tools` binary matching rustc; Xcode's LLVM is too old to read its data."""
    sysroot = subprocess.check_output(["rustc", "--print", "sysroot"], cwd=ROOT, text=True).strip()
    tool = Path(sysroot) / "lib" / "rustlib" / host_triple() / "bin" / name
    if not tool.exists():
        sys.exit(f"{tool} is missing; run: rustup component add llvm-tools")
    return str(tool)


def coverage_environment():
    """Instruments only this build, in its own target directory, without debug info."""
    environment = dict(os.environ)
    environment.update(
        RUSTFLAGS="-C instrument-coverage",
        CARGO_INCREMENTAL="0",
        CARGO_TARGET_DIR=str(OUTPUT),
        CARGO_PROFILE_DEV_DEBUG="0",
        CARGO_PROFILE_TEST_DEBUG="0",
        LLVM_PROFILE_FILE=str(PROFILES / "%p-%m.profraw"),
    )
    return environment


def cargo_test_arguments(jobs, host):
    """An explicit target keeps RUSTFLAGS off proc macros, which would drop profiles in sources."""
    arguments = ["cargo", "test", "--workspace", "--lib", "--bins", "--tests", "-j", str(jobs)]
    arguments += ["--target", host]
    for crate in sorted(EXCLUDED_CRATES):
        arguments += ["--exclude", crate]
    return arguments


def run_tests(jobs):
    """Runs every test with fresh profiles; returns whether they all passed."""
    shutil.rmtree(PROFILES, ignore_errors=True)
    PROFILES.mkdir(parents=True)
    command = [*cargo_test_arguments(jobs, host_triple()), "--no-fail-fast"]
    result = subprocess.run(command, cwd=ROOT, env=coverage_environment(), check=False)
    return result.returncode == 0


def test_executables(cargo_messages):
    """The test binaries named in cargo's JSON messages."""
    executables = []
    for line in cargo_messages.splitlines():
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if (
            message.get("reason") == "compiler-artifact"
            and message.get("executable")
            and message.get("profile", {}).get("test")
        ):
            executables.append(message["executable"])
    return executables


def export_lcov(jobs):
    """Merges the raw profiles and writes the lcov export."""
    profiles = sorted(str(path) for path in PROFILES.glob("*.profraw"))
    if not profiles:
        sys.exit(f"no coverage profiles in {PROFILES}: the test binaries didn't run")
    command = [*cargo_test_arguments(jobs, host_triple()), "--no-run", "--message-format=json"]
    messages = subprocess.run(
        command,
        cwd=ROOT,
        env=coverage_environment(),
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    objects = test_executables(messages)
    subprocess.run(
        [llvm_tool("llvm-profdata"), "merge", "-sparse", "-o", str(PROFDATA), *profiles],
        check=True,
    )
    object_arguments = [argument for path in objects for argument in ("-object", path)]
    export = subprocess.run(
        [
            llvm_tool("llvm-cov"),
            "export",
            "-format=lcov",
            f"-instr-profile={PROFDATA}",
            f"-ignore-filename-regex={IGNORED_SOURCES}",
            *object_arguments,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    LCOV.write_text(export.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--no-test", action="store_true", help="report on the last run's export")
    parser.add_argument("--jobs", type=int, default=4, help="cargo build jobs (default 4)")
    parser.add_argument("--top", type=int, default=20, help="how many of the worst files to print")
    parser.add_argument("--excluded", action="store_true", help="list coverage:off ranges")
    arguments = parser.parse_args()

    tests_passed = True
    if not arguments.no_test:
        tests_passed = run_tests(arguments.jobs)
        export_lcov(arguments.jobs)
    if not LCOV.exists():
        sys.exit(f"{LCOV} is missing; run without --no-test first")

    rows = summarize(parse_lcov(LCOV.read_text()))
    totals = crate_totals(rows)
    listing = uncovered_listing(rows)
    UNCOVERED.write_text("".join(f"{line}\n" for line in listing))

    for line in listing[: arguments.top]:
        print(line.split(": ")[0])
    print_totals(totals)
    print(f"missed line ranges: {UNCOVERED}")
    if arguments.excluded:
        for relative, _kept, reasons in rows:
            for start, end, reason in reasons:
                print(f"{relative}:{start}-{end}: {reason}")

    unmeasured = unmeasured_crates(totals, workspace_crates())
    if unmeasured:
        print(f"no coverage measured for: {', '.join(unmeasured)}", file=sys.stderr)
    if not tests_passed:
        print("tests failed", file=sys.stderr)
    return 1 if unmeasured or not tests_passed else 0


if __name__ == "__main__":
    sys.exit(main())
