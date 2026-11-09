#!/usr/bin/env python3
"""Line coverage of the Apple packages from their own fast tests.

Usage: coverage.py [--package NAME ...] [--no-test] [--uncovered PATH_SUBSTRING]

Runs each package's offscreen-safe tests with coverage on, then reports its source lines. Tests
that open real windows or need a live server are left out, here and in CI's fast tier; the VM
flows in Tests/OmnigentMacUITests cover those.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGES = ROOT / "Packages"

# Generated bindings, a shim and test helpers are not product code.
EXCLUDED_PACKAGES = {"OmnigentCoreFFI", "OmnigentGhosttyKit", "OmnigentTestSupport"}

# Per-package `swift test` arguments.
TEST_ARGUMENTS = {
    "OmnigentTerminalUI": [
        "--filter",
        "HostileConfigTests|HostilePreferencesTests|HostileEchoShellTests|HostileRecordingTests"
        "|HostileDemoAndInputTests|OffscreenSurfaceTests|OffscreenCommandTests|HostileBytesTests"
        "|SurfaceKeyboardTests|SurfaceMouseTests|TerminalViewRenderTests|HostileConnectionTests",
    ],
    "OmnigentRemoteBrowser": [
        "--skip",
        "RemoteBrowserE2ETests",
        "--skip",
        "RemoteBrowserViewE2ETests",
    ],
    "OmnigentBrowser": ["--filter", "OmnigentBrowserChromiumTests"],
}


def line_ranges(lines):
    """Compresses sorted line numbers to `a-b` ranges."""
    ranges, start, previous = [], None, None
    for line in lines:
        if start is None:
            start = previous = line
        elif line == previous + 1:
            previous = line
        else:
            ranges.append(f"{start}-{previous}" if start != previous else str(start))
            start = previous = line
    if start is not None:
        ranges.append(f"{start}-{previous}" if start != previous else str(start))
    return ranges


def uncovered_lines(segments):
    """Lines with code and no hits, from llvm-cov's segments."""
    uncovered, covered = set(), set()
    for index, segment in enumerate(segments):
        line, _column, count, has_count, _entry, gap = segment
        if not has_count or gap:
            continue
        end = segments[index + 1][0] if index + 1 < len(segments) else line
        for number in range(line, end + 1):
            (covered if count else uncovered).add(number)
    return sorted(uncovered - covered)


def summarize(document, sources):
    """Per-file `(path, covered, total, segments)` for files under `sources`."""
    prefix = str(sources) + "/"
    rows = []
    for export in document["data"]:
        for entry in export["files"]:
            if entry["filename"].startswith(prefix):
                lines = entry["summary"]["lines"]
                rows.append(
                    (entry["filename"], lines["covered"], lines["count"], entry["segments"])
                )
    return rows


def run_package(name, should_test):
    """Runs one package's tests and returns its coverage rows and whether they passed."""
    path = PACKAGES / name
    base = ["swift", "test", "--package-path", str(path), "--enable-code-coverage"]
    if should_test:
        command = [*base, "--no-parallel", *TEST_ARGUMENTS.get(name, [])]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            tail = result.stdout[-2000:] + result.stderr[-1000:]
            print(f"{name}: tests failed\n{tail}", file=sys.stderr)
    else:
        result = None
    codecov = subprocess.run(
        [*base, "--show-codecov-path"], capture_output=True, text=True, check=True
    ).stdout.strip()
    rows = summarize(json.loads(Path(codecov).read_text()), path / "Sources")
    return rows, (result is None or result.returncode == 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", action="append", help="Only this package; repeatable.")
    parser.add_argument("--no-test", action="store_true", help="Report the last run's data.")
    parser.add_argument("--uncovered", help="List uncovered lines of files matching this text.")
    parser.add_argument(
        "--files", action="store_true", help="List every file, least covered first."
    )
    options = parser.parse_args()
    names = options.package or sorted(
        path.name
        for path in PACKAGES.iterdir()
        if (path / "Package.swift").exists() and path.name not in EXCLUDED_PACKAGES
    )
    total_covered = total_lines = 0
    failed = []
    for name in names:
        rows, passed = run_package(name, not options.no_test)
        if not passed:
            failed.append(name)
        covered = sum(row[1] for row in rows)
        lines = sum(row[2] for row in rows)
        total_covered += covered
        total_lines += lines
        percent = 100 * covered / lines if lines else 100
        print(f"{percent:6.1f}%  {covered:>6}/{lines:<6}  {name}", flush=True)
        for path, file_covered, file_lines, segments in sorted(
            rows, key=lambda row: row[1] / max(row[2], 1)
        ):
            if options.files and file_covered < file_lines:
                short = path.split("/Sources/", 1)[1]
                share = 100 * file_covered / max(file_lines, 1)
                missing = file_lines - file_covered
                print(f"        {share:5.1f}%  {missing:>5} missing  {short}")
            if options.uncovered and options.uncovered in path:
                print(f"        {path}: {' '.join(line_ranges(uncovered_lines(segments)))}")
    percent = 100 * total_covered / total_lines if total_lines else 100
    print(f"{percent:6.1f}%  {total_covered:>6}/{total_lines:<6}  total")
    if failed:
        print(f"Tests failed in: {', '.join(failed)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
