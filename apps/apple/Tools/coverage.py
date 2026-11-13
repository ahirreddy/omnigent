#!/usr/bin/env python3
"""Line coverage of the Apple packages from their own fast tests.

Usage: coverage.py [--package NAME ...] [--no-test] [--uncovered PATH_SUBSTRING] [--excluded]
                   [--unmeasured] [--ios] [--simulator NAME] [--source-packages DIR]
                   [--no-mac-test]
       coverage.py --hosted XCRESULT [--files] [--uncovered PATH_SUBSTRING] [--excluded]

Runs each package's offscreen-safe tests with coverage on, then reports its source lines. Tests
that open real windows or need a live server are left out, here and in CI's fast tier; the VM
flows in Tests/OmnigentMacUITests cover those.

`--ios` also runs the tests of each package with files only an iOS build compiles on an iOS
simulator, and reports those files in rows and a total of their own; the Mac rows don't change.
`--source-packages` names a folder of package checkouts to use where their origins are unreachable.
`--no-mac-test` reports the Mac rows from the last run's data and still runs the simulator's tests.

`--hosted` instead reads the macOS app target's own code from a result bundle of its hosted tests.

Previews and the design gallery don't count. Code only a real window can reach goes between
`// coverage:off <what reaches it instead>` and `// coverage:on`; `--excluded` lists those reasons.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGES = ROOT / "Packages"

# Generated bindings, a shim and test helpers are not product code.
EXCLUDED_PACKAGES = {"OmnigentCoreFFI", "OmnigentGhosttyKit", "OmnigentTestSupport"}

# Design samples, which only the gallery and previews open.
EXCLUDED_SOURCES = re.compile(r"/Gallery/|/Preview/|Playground[^/]*\.swift$|Previews\.swift$")

COVERAGE_OFF = re.compile(r"^\s*// coverage:off(?:\s+(.*\S))?\s*$")
COVERAGE_ON = re.compile(r"^\s*// coverage:on\s*$")
PREVIEW = re.compile(r"^(\s*)#Preview\b")
PROTOCOL = re.compile(r"^\s*(?:(?:public|private|fileprivate|nonisolated|@\w+)\s+)*protocol\s")
EXECUTABLE_CODE = re.compile(r"\b(func|init|get|set|didSet|willSet)\b|\bvar \w+[^=\n]*\{")

# The app target the hosted tests measure; its VM-only chaos driver and generated code don't count.
HOSTED_TARGET = "Omnigent.app"
HOSTED_EXCLUDED_FILES = re.compile(r"/(Chaos[^/]*|TuistBundle[^/]*)\.swift$")

# Per-package `swift test` arguments.
TEST_ARGUMENTS = {
    "OmnigentTerminalUI": [
        "--filter",
        "HostileConfigTests|HostilePreferencesTests|HostileEchoShellTests|HostileRecordingTests"
        "|HostileDemoAndInputTests|OffscreenSurfaceTests|OffscreenCommandTests|HostileBytesTests"
        "|SurfaceKeyboardTests|SurfaceMouseTests|TerminalViewRenderTests|HostileConnectionTests"
        "|TerminalClipboardTests|TerminalStatusOverlayTests|TerminalFindBarTests|TerminalListTests"
        "|TerminalSettingsTests|AttachedTerminalOverlayTests|SurfaceContextMenuTests"
        "|TerminalPreferencesTests|ClipboardPolicyTests|ConfigAndInputTests|FakeConnectionTests"
        "|SurfacePixelSizeTests|TerminalKeyboardFocusTests",
    ],
    "OmnigentRemoteBrowser": [
        "--skip",
        "RemoteBrowserE2ETests",
        "--skip",
        "RemoteBrowserViewE2ETests",
    ],
    # Left out: the login Keychain test, and the agent panel, which orders a window in.
    "OmnigentBrowser": [
        "--skip",
        "KeychainCredentialStoreTests",
        "--skip",
        "AgentBrowserWebKitTests",
    ],
}


# Where the simulator runs build and leave their result bundles; one build serves every package.
IOS_BUILD = ROOT / ".build" / "ios-coverage"
IOS_SIMULATOR = "iPhone 18 Pro"

# Per-package `xcodebuild test` arguments on the simulator. Left out: the live host test.
IOS_TEST_ARGUMENTS = {
    "OmnigentRemoteBrowser": ["-skip-testing:OmnigentRemoteBrowserTests/RemoteBrowserE2ETests"],
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


def line_coverage(segments):
    """The `(covered, uncovered)` line sets from llvm-cov's segments; any hit covers a line."""
    uncovered, covered = set(), set()
    for index, segment in enumerate(segments):
        line, _column, count, has_count, _entry, gap = segment
        if not has_count or gap:
            continue
        end = segments[index + 1][0] if index + 1 < len(segments) else line
        for number in range(line, end + 1):
            (covered if count else uncovered).add(number)
    return covered, uncovered - covered


def uncovered_lines(segments):
    """Lines with code and no hits, from llvm-cov's segments."""
    return sorted(line_coverage(segments)[1])


def excluded_lines(source):
    """Lines that don't count, and the reasons given: `#Preview` blocks and marked ranges."""
    lines = source.splitlines()
    excluded, reasons = set(), []
    open_from = reason = None
    index = 0
    while index < len(lines):
        number = index + 1
        off = COVERAGE_OFF.match(lines[index])
        preview = PREVIEW.match(lines[index])
        if off:
            if open_from is not None:
                raise ValueError(f"line {number}: coverage:off inside the one at {open_from}")
            if not off.group(1):
                raise ValueError(f"line {number}: coverage:off must say what reaches this code")
            open_from, reason = number, off.group(1)
        elif COVERAGE_ON.match(lines[index]):
            if open_from is None:
                raise ValueError(f"line {number}: coverage:on without coverage:off")
            excluded.update(range(open_from, number + 1))
            reasons.append((open_from, number, reason))
            open_from = None
        elif preview:
            closing = preview.group(1) + "}"
            end = next(
                (
                    later
                    for later in range(index + 1, len(lines))
                    if lines[later].rstrip() == closing
                ),
                None,
            )
            if end is None:
                raise ValueError(f"line {number}: no closing brace for this #Preview")
            excluded.update(range(number, end + 2))
            index = end
        index += 1
    if open_from is not None:
        raise ValueError(f"line {open_from}: coverage:off without coverage:on")
    return excluded, reasons


def summarize(document, sources, read_source=None):
    """Per-file `(path, covered, total, segments, reasons)` for counted files under `sources`."""
    read_source = read_source or (lambda path: Path(path).read_text(encoding="utf-8"))
    prefix = str(sources) + "/"
    rows = {}
    for export in document["data"]:
        for entry in export["files"]:
            path = entry["filename"]
            if not path.startswith(prefix) or EXCLUDED_SOURCES.search(path):
                continue
            try:
                excluded, reasons = excluded_lines(read_source(path))
            except ValueError as error:
                raise SystemExit(f"{path}: {error}") from error
            covered, uncovered = line_coverage(entry["segments"])
            counted_covered = len(covered - excluded)
            counted = counted_covered + len(uncovered - excluded)
            rows[path] = (path, counted_covered, counted, entry["segments"], reasons)
    return list(rows.values())


def hosted_files(listing):
    """The source paths in xccov's `--files-for-target` listing, without those that don't count.

    The name also matches the App Store edition's app, which builds the same sources.
    """
    product = f"/{HOSTED_TARGET}/"
    paths = dict.fromkeys(
        file["path"]
        for target in listing
        if product in target["product"]
        for file in target["files"]
    )
    return [path for path in paths if not HOSTED_EXCLUDED_FILES.search(path)]


def summarize_hosted(paths, archive, read_source=None):
    """Per-file `(path, covered, total, missing_lines, reasons)` from xccov's `--archive` lines."""
    read_source = read_source or (lambda path: Path(path).read_text(encoding="utf-8"))
    rows = []
    for path in paths:
        try:
            excluded, reasons = excluded_lines(read_source(path))
        except ValueError as error:
            raise SystemExit(f"{path}: {error}") from error
        counted = [
            line
            for line in archive.get(path, [])
            if line["isExecutable"] and line["line"] not in excluded
        ]
        missing = sorted(line["line"] for line in counted if not line["executionCount"])
        rows.append((path, len(counted) - len(missing), len(counted), missing, reasons))
    return rows


def view_result_bundle(result_bundle, *arguments):
    """xccov's JSON for a result bundle: `--archive` is every file's lines."""
    command = ["xcrun", "xccov", "view", *arguments, "--json", str(result_bundle)]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise SystemExit(f"{result_bundle}: xccov failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def read_hosted(result_bundle):
    """Reads the app target's coverage rows from a result bundle."""
    listing = view_result_bundle(result_bundle, "--report", "--files-for-target", HOSTED_TARGET)
    archive = view_result_bundle(result_bundle, "--archive")
    rows = summarize_hosted(hosted_files(listing), archive)
    # No lines means the bundle didn't measure the target, which must not read as full coverage.
    if not any(row[2] for row in rows):
        raise SystemExit(f"{result_bundle}: no coverage for {HOSTED_TARGET}.")
    return rows


def print_hosted(rows, options):
    """Prints the app target's total and what `--files`, `--uncovered` and `--excluded` ask for."""
    print_archive_rows(HOSTED_TARGET, rows, options)


def print_archive_rows(title, rows, options):
    """Prints a total for rows read from xccov, and the details the options ask for."""
    covered = sum(row[1] for row in rows)
    lines = sum(row[2] for row in rows)
    percent = 100 * covered / lines if lines else 100
    print(f"{percent:6.1f}%  {covered:>6}/{lines:<6}  {title}", flush=True)
    for path, file_covered, file_lines, missing, reasons in sorted(
        rows, key=lambda row: row[1] - row[2]
    ):
        short = path.split("/Sources/", 1)[-1]
        if options.excluded:
            for start, end, reason in reasons:
                print(f"        {short}:{start}-{end}  {reason}")
        if options.files and missing:
            share = 100 * file_covered / max(file_lines, 1)
            print(f"        {share:5.1f}%  {len(missing):>5} missing  {short}")
        if options.uncovered and options.uncovered in path and missing:
            print(f"        {path}: {' '.join(line_ranges(missing))}")


def unmeasured_files(document, sources):
    """`(path, code_lines)` of code under `sources` that no test bundle built, largest first.

    Mostly `#if os(iOS)` files and targets without a test target. Their lines aren't in any total.
    """
    measured = {entry["filename"] for export in document["data"] for entry in export["files"]}
    rows = []
    for path in Path(sources).rglob("*.swift"):
        if str(path) in measured or EXCLUDED_SOURCES.search(str(path)):
            continue
        text = path.read_text(encoding="utf-8")
        code = [
            line
            for line in text.splitlines()
            if line.strip() and not line.lstrip().startswith("//")
        ]
        # A comment's words ("the set the app draws") and a protocol's requirements are not code.
        if EXECUTABLE_CODE.search("\n".join(without_protocols(code))):
            rows.append((str(path), len(code)))
    return sorted(rows, key=lambda row: -row[1])


def without_protocols(lines):
    """`lines` without protocol declarations, whose `func` and `get` have no bodies to run."""
    kept, depth = [], None
    for line in lines:
        if depth is None and PROTOCOL.match(line):
            depth = 0
        if depth is None:
            kept.append(line)
            continue
        depth += line.count("{") - line.count("}")
        if depth <= 0 and "}" in line:
            depth = None
    return kept


def ios_scheme(name, schemes):
    """The scheme that runs a package's tests: xcodebuild adds `-Package` for several products."""
    for candidate in (f"{name}-Package", name):
        if candidate in schemes:
            return candidate
    raise SystemExit(f"{name}: no scheme for its tests among {', '.join(schemes) or 'none'}.")


def source_package_arguments(source_packages):
    """`xcodebuild` arguments that resolve remote packages from a folder of checkouts, offline."""
    if not source_packages:
        return []
    return [
        "-clonedSourcePackagesDirPath",
        str(source_packages),
        "-disableAutomaticPackageResolution",
        "-skipPackageUpdates",
    ]


def ios_test_command(name, scheme, simulator, result_bundle, source_packages=None):
    """The `xcodebuild test` call that runs a package's tests on a simulator with coverage."""
    return [
        "xcodebuild",
        "test",
        "-scheme",
        scheme,
        "-destination",
        f"platform=iOS Simulator,name={simulator}",
        "-enableCodeCoverage",
        "YES",
        "-derivedDataPath",
        str(IOS_BUILD / "DerivedData"),
        "-resultBundlePath",
        str(result_bundle),
        *source_package_arguments(source_packages),
        *IOS_TEST_ARGUMENTS.get(name, []),
    ]


def summarize_ios(unmeasured, archive, read_source=None):
    """Splits `unmeasured` into coverage rows for the files `archive` has lines for, and the rest.

    The rows are `summarize_hosted`'s; the rest stay `(path, code_lines)`.
    """
    built = [
        path
        for path, _lines in unmeasured
        if any(line["isExecutable"] for line in archive.get(path, []))
    ]
    rest = [row for row in unmeasured if row[0] not in built]
    return summarize_hosted(built, archive, read_source), rest


def run_ios_package(name, simulator, should_test, source_packages=None):
    """Runs one package's tests on a simulator: xccov's lines per file, `None` if they failed."""
    path = PACKAGES / name
    result_bundle = IOS_BUILD / f"{name}.xcresult"
    if should_test:
        list_schemes = ["xcodebuild", "-list", "-json", *source_package_arguments(source_packages)]
        listing = subprocess.run(
            list_schemes, cwd=path, capture_output=True, text=True, check=True
        )
        scheme = ios_scheme(name, json.loads(listing.stdout)["workspace"]["schemes"])
        if result_bundle.exists():
            # xcodebuild refuses to write over an earlier run's bundle.
            shutil.rmtree(result_bundle)
        command = ios_test_command(name, scheme, simulator, result_bundle, source_packages)
        result = subprocess.run(command, cwd=path, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            output = result.stdout + result.stderr
            failures = [
                line for line in output.splitlines() if "\u2718" in line or "error:" in line
            ]
            shown = "\n".join(failures[:40]) or output[-2000:]
            print(f"{name}: iOS tests failed\n{shown}", file=sys.stderr)
            return None
    if not result_bundle.exists():
        raise SystemExit(f"{name}: no simulator run to report; run with --ios, without --no-test.")
    return view_result_bundle(result_bundle, "--archive")


def screen_is_locked(registry=None):
    """Whether the login session's screen is locked, which stops offscreen clicks landing."""
    if registry is None:
        registry = subprocess.run(
            ["ioreg", "-n", "Root", "-d1", "-a"], capture_output=True, text=True, check=True
        ).stdout
    return re.search(r"<key>CGSSessionScreenIsLocked</key>\s*<true/>", registry) is not None


def export_all_bundles(json_path):
    """Exports every test bundle of a package: SwiftPM's own JSON covers only one of them."""
    products = Path(json_path).parent.parent
    bundles = sorted(products.glob("*.xctest"))
    binaries = [bundle / "Contents" / "MacOS" / bundle.stem for bundle in bundles]
    objects = [argument for binary in binaries[1:] for argument in ("-object", str(binary))]
    profile = Path(json_path).parent / "default.profdata"
    command = ["xcrun", "llvm-cov", "export", f"-instr-profile={profile}", str(binaries[0])]
    result = subprocess.run([*command, *objects], capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def run_package(name, should_test):
    """Runs one package's tests: its coverage rows, whether they passed, and unmeasured files."""
    path = PACKAGES / name
    base = ["swift", "test", "--package-path", str(path), "--enable-code-coverage"]
    if should_test:
        command = [*base, "--no-parallel", *TEST_ARGUMENTS.get(name, [])]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            output = result.stdout + result.stderr
            failures = [
                line for line in output.splitlines() if "\u2718" in line or "error:" in line
            ]
            shown = "\n".join(failures[:40]) or output[-2000:]
            print(f"{name}: tests failed\n{shown}", file=sys.stderr)
            # A failed run may leave no profile to export, and the rest still need measuring.
            return [], False, []
    else:
        result = None
    codecov = subprocess.run(
        [*base, "--show-codecov-path"], capture_output=True, text=True, check=True
    ).stdout.strip()
    document = export_all_bundles(codecov)
    rows = summarize(document, path / "Sources")
    # No lines means the export missed this package, which must not read as full coverage.
    if not any(row[2] for row in rows):
        raise SystemExit(f"{name}: coverage data has no lines for this package's sources.")
    return (
        rows,
        (result is None or result.returncode == 0),
        unmeasured_files(document, path / "Sources"),
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", action="append", help="Only this package; repeatable.")
    parser.add_argument("--no-test", action="store_true", help="Report the last run's data.")
    parser.add_argument("--uncovered", help="List uncovered lines of files matching this text.")
    parser.add_argument(
        "--files", action="store_true", help="List every file, least covered first."
    )
    parser.add_argument(
        "--excluded", action="store_true", help="List code marked coverage:off and why."
    )
    parser.add_argument(
        "--unmeasured", action="store_true", help="List code no test bundle builds on this Mac."
    )
    parser.add_argument(
        "--hosted", metavar="XCRESULT", help="Report the app target from this result bundle."
    )
    parser.add_argument(
        "--ios", action="store_true", help="Measure iOS-only files on an iOS simulator too."
    )
    parser.add_argument(
        "--simulator", default=IOS_SIMULATOR, help=f"The simulator's name ({IOS_SIMULATOR})."
    )
    parser.add_argument(
        "--source-packages", metavar="DIR", help="Remote packages' checkouts, to build offline."
    )
    parser.add_argument(
        "--no-mac-test", action="store_true", help="Reuse the Mac data; still run the simulator."
    )
    options = parser.parse_args()
    tests_mac = not options.no_test and not options.no_mac_test
    if tests_mac and not options.hosted and screen_is_locked():
        # Clicks on borderless buttons and other controls fail while locked, as if broken.
        raise SystemExit("The screen is locked: view tests can't click. Unlock it and run again.")
    if options.hosted:
        print_hosted(read_hosted(options.hosted), options)
        return 0
    names = options.package or sorted(
        path.name
        for path in PACKAGES.iterdir()
        if (path / "Package.swift").exists() and path.name not in EXCLUDED_PACKAGES
    )
    total_covered = total_lines = 0
    failed = []
    unmeasured = []
    ios_rows = []
    for name in names:
        rows, passed, package_unmeasured = run_package(name, tests_mac)
        package_ios_rows = []
        if options.ios and package_unmeasured:
            archive = run_ios_package(
                name, options.simulator, not options.no_test, options.source_packages
            )
            if archive is None:
                failed.append(f"{name} (iOS)")
            else:
                package_ios_rows, package_unmeasured = summarize_ios(package_unmeasured, archive)
        unmeasured += package_unmeasured
        ios_rows += package_ios_rows
        if not passed:
            # The profile on disk may be from an older run, so it says nothing about this one.
            failed.append(name)
            print(f"    n/a  tests failed   {name}", flush=True)
            continue
        covered = sum(row[1] for row in rows)
        lines = sum(row[2] for row in rows)
        total_covered += covered
        total_lines += lines
        percent = 100 * covered / lines if lines else 100
        print(f"{percent:6.1f}%  {covered:>6}/{lines:<6}  {name}", flush=True)
        for path, file_covered, file_lines, segments, reasons in sorted(
            rows, key=lambda row: row[1] / max(row[2], 1)
        ):
            if options.excluded:
                short = path.split("/Sources/", 1)[1]
                for start, end, reason in reasons:
                    print(f"        {short}:{start}-{end}  {reason}")
            if options.files and file_covered < file_lines:
                short = path.split("/Sources/", 1)[1]
                share = 100 * file_covered / max(file_lines, 1)
                missing = file_lines - file_covered
                print(f"        {share:5.1f}%  {missing:>5} missing  {short}")
            if options.uncovered and options.uncovered in path:
                excluded, _ = excluded_lines(Path(path).read_text(encoding="utf-8"))
                missing_lines = [
                    line for line in uncovered_lines(segments) if line not in excluded
                ]
                print(f"        {path}: {' '.join(line_ranges(missing_lines))}")
        if package_ios_rows:
            title = f"{name}, {len(package_ios_rows)} iOS-only files on the simulator"
            print_archive_rows(title, package_ios_rows, options)
    if total_lines:
        percent = 100 * total_covered / total_lines
        print(f"{percent:6.1f}%  {total_covered:>6}/{total_lines:<6}  total")
    else:
        print("    n/a  no coverage measured")
    if ios_rows:
        # Its own total: another platform's run, counted by xccov and not from llvm-cov's segments.
        summary_only = argparse.Namespace(excluded=False, files=False, uncovered=None)
        print_archive_rows("iOS-only files, on the simulator", ios_rows, summary_only)
    if unmeasured:
        # A total must not read as all the code: iOS files and untested targets aren't in it.
        lines = sum(row[1] for row in unmeasured)
        print(f"Not in the total: {lines} lines in {len(unmeasured)} files no test here builds.")
        if options.unmeasured:
            for path, code_lines in unmeasured:
                print(f"        {code_lines:>5} lines  {path.split('/Sources/', 1)[1]}")
    if failed:
        print(f"Tests failed in: {', '.join(failed)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
