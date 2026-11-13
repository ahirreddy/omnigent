"""The coverage report reads llvm-cov's segments correctly."""

import argparse
import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("coverage", Path(__file__).with_name("coverage.py"))
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)


class CoverageTests(unittest.TestCase):
    def test_ranges_compress_runs(self):
        self.assertEqual(coverage.line_ranges([1, 2, 3, 7, 9, 10]), ["1-3", "7", "9-10"])
        self.assertEqual(coverage.line_ranges([]), [])

    def test_uncovered_lines_skip_gaps_and_covered_lines(self):
        segments = [
            [1, 1, 5, True, True, False],
            [3, 1, 0, True, False, False],
            [5, 1, 0, False, False, False],
            [6, 1, 0, True, False, True],
        ]
        self.assertEqual(coverage.uncovered_lines(segments), [4, 5])

    @staticmethod
    def entry(path, segments):
        return {"filename": path, "segments": segments}

    def test_summary_keeps_only_files_under_sources(self):
        hit = [
            [1, 1, 1, True, True, False],
            [2, 1, 0, True, False, False],
            [3, 1, 0, False, False, False],
        ]
        document = {
            "data": [
                {
                    "files": [
                        self.entry("/p/Sources/A.swift", hit),
                        self.entry("/p/Tests/B.swift", hit),
                    ]
                }
            ]
        }
        rows = coverage.summarize(document, Path("/p/Sources"), read_source=lambda _path: "")
        self.assertEqual(rows, [("/p/Sources/A.swift", 2, 3, hit, [])])

    def test_summary_leaves_out_design_samples(self):
        samples = ["Gallery/Sample", "Preview/Data", "Tabs/TabsPlayground", "CLI/CLIPreviews"]
        files = [self.entry(f"/p/Sources/{sample}.swift", []) for sample in samples]
        document = {"data": [{"files": files}]}
        self.assertEqual(
            coverage.summarize(document, Path("/p/Sources"), read_source=lambda _path: ""), []
        )

    def test_summary_merges_a_file_seen_in_two_bundles_once(self):
        document = {
            "data": [
                {
                    "files": [
                        self.entry("/p/Sources/A.swift", []),
                        self.entry("/p/Sources/A.swift", []),
                    ]
                }
            ]
        }
        rows = coverage.summarize(document, Path("/p/Sources"), read_source=lambda _path: "")
        self.assertEqual(len(rows), 1)

    def test_summary_does_not_count_excluded_lines(self):
        segments = [[1, 1, 0, True, True, False], [5, 1, 0, False, False, False]]
        source = "// coverage:off VM flow testDrag\nlet a = 1\n// coverage:on\nlet b = 2\n"
        rows = coverage.summarize(
            {"data": [{"files": [self.entry("/p/Sources/A.swift", segments)]}]},
            Path("/p/Sources"),
            read_source=lambda _path: source,
        )
        self.assertEqual(rows[0][1:3], (0, 2))
        self.assertEqual(rows[0][4], [(1, 3, "VM flow testDrag")])

    def test_summary_names_the_file_with_a_bad_marker(self):
        document = {"data": [{"files": [self.entry("/p/Sources/A.swift", [])]}]}
        with self.assertRaisesRegex(SystemExit, "A.swift: line 1"):
            coverage.summarize(
                document, Path("/p/Sources"), read_source=lambda _path: "// coverage:on\n"
            )

    def test_unmeasured_lists_code_no_bundle_built(self):
        with tempfile.TemporaryDirectory() as directory:
            sources = Path(directory)
            (sources / "Built.swift").write_text("func a() {}\n")
            (sources / "Phone.swift").write_text("#if os(iOS)\n// note\nfunc b() {}\n#endif\n")
            (sources / "Types.swift").write_text("enum Kind { case one }\n")
            (sources / "TabsPlayground.swift").write_text("func c() {}\n")
            document = {"data": [{"files": [{"filename": str(sources / "Built.swift")}]}]}
            self.assertEqual(
                coverage.unmeasured_files(document, sources), [(str(sources / "Phone.swift"), 3)]
            )

    def test_unmeasured_ignores_a_data_file_whose_comment_has_a_code_word(self):
        with tempfile.TemporaryDirectory() as directory:
            sources = Path(directory)
            (sources / "Art.swift").write_text(
                '// Path data from the set the web app draws.\nlet art = [\n  "M1 2",\n]\n'
            )
            (sources / "Code.swift").write_text("// A note.\nvar size: Int { 1 }\n")
            self.assertEqual(
                coverage.unmeasured_files({"data": []}, sources),
                [(str(sources / "Code.swift"), 1)],
            )

    def test_unmeasured_ignores_a_file_of_protocols_and_empty_conformances(self):
        with tempfile.TemporaryDirectory() as directory:
            sources = Path(directory)
            (sources / "Receiving.swift").write_text(
                "protocol Receiving: Sendable {\n  func chunk(bytes: Data)\n"
                "  var count: Int { get }\n}\n\nextension Sink: Receiving {}\n"
            )
            (sources / "Mixed.swift").write_text(
                "public protocol Naming {\n  func name() -> String\n}\n\n"
                "extension Naming {\n  func shout() -> String { name().uppercased() }\n}\n"
            )
            self.assertEqual(
                coverage.unmeasured_files({"data": []}, sources),
                [(str(sources / "Mixed.swift"), 6)],
            )

    def test_ios_scheme_is_the_package_scheme_when_there_are_several_products(self):
        self.assertEqual(
            coverage.ios_scheme("Kit", ["Kit", "Kit-Package", "KitExtras"]), "Kit-Package"
        )
        self.assertEqual(coverage.ios_scheme("Kit", ["Kit"]), "Kit")
        with self.assertRaisesRegex(SystemExit, "Kit: no scheme for its tests among Other"):
            coverage.ios_scheme("Kit", ["Other"])
        with self.assertRaisesRegex(SystemExit, "among none"):
            coverage.ios_scheme("Kit", [])

    def test_ios_tests_run_on_the_named_simulator_with_coverage(self):
        bundle = Path("/b/Kit.xcresult")
        command = coverage.ios_test_command("Kit", "Kit-Package", "iPad Pro 13-inch (M5)", bundle)
        self.assertEqual(command[:4], ["xcodebuild", "test", "-scheme", "Kit-Package"])
        destination = command[command.index("-destination") + 1]
        self.assertEqual(destination, "platform=iOS Simulator,name=iPad Pro 13-inch (M5)")
        self.assertEqual(command[command.index("-enableCodeCoverage") + 1], "YES")
        self.assertEqual(command[command.index("-resultBundlePath") + 1], str(bundle))
        self.assertEqual(
            command[command.index("-derivedDataPath") + 1],
            str(coverage.IOS_BUILD / "DerivedData"),
        )
        self.assertEqual(command[-1], str(bundle))

    def test_ios_tests_can_build_from_a_folder_of_package_checkouts_offline(self):
        self.assertEqual(coverage.source_package_arguments(None), [])
        command = coverage.ios_test_command("Kit", "Kit", "iPhone 18 Pro", Path("/b/r"), "/sp")
        self.assertEqual(
            command[-4:],
            [
                "-clonedSourcePackagesDirPath",
                "/sp",
                "-disableAutomaticPackageResolution",
                "-skipPackageUpdates",
            ],
        )

    def test_ios_tests_leave_out_what_the_package_says_needs_a_live_host(self):
        command = coverage.ios_test_command(
            "OmnigentRemoteBrowser", "OmnigentRemoteBrowser", "iPhone 18 Pro", Path("/b/r")
        )
        self.assertEqual(
            command[-1], "-skip-testing:OmnigentRemoteBrowserTests/RemoteBrowserE2ETests"
        )

    def test_ios_summary_measures_the_files_the_simulator_built_and_keeps_the_rest(self):
        source = "a\nb\n// coverage:off a real finger\nc\n// coverage:on\n"
        archive = {
            "/p/Sources/Touch.swift": [
                {"line": 1, "isExecutable": True, "executionCount": 2},
                {"line": 2, "isExecutable": True, "executionCount": 0},
                {"line": 4, "isExecutable": True, "executionCount": 0},
            ],
            # Built for iOS too, but the Mac bundles measured it: not this run's to report.
            "/p/Sources/Shared.swift": [{"line": 1, "isExecutable": True, "executionCount": 1}],
            # Listed with no code that runs.
            "/p/Sources/Types.swift": [{"line": 1, "isExecutable": False}],
        }
        unmeasured = [
            ("/p/Sources/Touch.swift", 40),
            ("/p/Sources/Types.swift", 9),
            ("/p/Sources/MacSample.swift", 7),
        ]
        rows, rest = coverage.summarize_ios(unmeasured, archive, read_source=lambda _path: source)
        self.assertEqual(rows, [("/p/Sources/Touch.swift", 1, 2, [2], [(3, 5, "a real finger")])])
        self.assertEqual(rest, [("/p/Sources/Types.swift", 9), ("/p/Sources/MacSample.swift", 7)])

    def test_archive_rows_print_a_total_then_the_details_asked_for(self):
        rows = [
            ("/p/Sources/Kit/Touch.swift", 1, 3, [2, 3], [(7, 9, "a real finger")]),
            ("/p/Sources/Kit/Keys.swift", 2, 2, [], []),
        ]
        options = argparse.Namespace(excluded=True, files=True, uncovered="Touch")
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            coverage.print_archive_rows("Kit, 2 iOS-only files on the simulator", rows, options)
        self.assertEqual(
            printed.getvalue().splitlines(),
            [
                "  60.0%       3/5       Kit, 2 iOS-only files on the simulator",
                "        Kit/Touch.swift:7-9  a real finger",
                "         33.3%      2 missing  Kit/Touch.swift",
                "        /p/Sources/Kit/Touch.swift: 2-3",
            ],
        )
        summary = argparse.Namespace(excluded=False, files=False, uncovered=None)
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            coverage.print_archive_rows("iOS-only files", [], summary)
        self.assertEqual(printed.getvalue(), " 100.0%       0/0       iOS-only files\n")

    def test_screen_lock_reads_the_session_flag(self):
        locked = "<key>CGSSessionScreenIsLocked</key>\n\t\t\t<true/>"
        self.assertTrue(coverage.screen_is_locked(locked))
        self.assertFalse(coverage.screen_is_locked(locked.replace("true", "false")))
        self.assertFalse(coverage.screen_is_locked("<key>Other</key><true/>"))

    def test_excluded_lines_take_whole_previews(self):
        source = (
            'let a = 1\n#Preview {\n  Text("x")\n}\nlet b = 2\n  #Preview("t") {\n  }\nlet c = 3\n'
        )
        self.assertEqual(coverage.excluded_lines(source), ({2, 3, 4, 6, 7}, []))

    def test_excluded_lines_reject_marker_mistakes(self):
        for source, message in [
            ("// coverage:off\n// coverage:on\n", "must say what reaches"),
            ("// coverage:off a\n", "without coverage:on"),
            ("// coverage:on\n", "without coverage:off"),
            ("// coverage:off a\n// coverage:off b\n", "inside the one"),
            ("#Preview {\n", "no closing brace"),
        ]:
            with self.subTest(source=source), self.assertRaisesRegex(ValueError, message):
                coverage.excluded_lines(source)

    def test_hosted_files_are_the_developer_id_apps_once_without_chaos_or_generated(self):
        files = [
            {"path": "/p/Sources/App.swift"},
            {"path": "/p/Sources/ChaosDriver.swift"},
            {"path": "/p/Derived/Sources/TuistBundle+Omnigent.swift"},
        ]
        listing = [
            {"product": "/d/OmnigentAppStore.app/Contents/MacOS/OmnigentAppStore", "files": files},
            {"product": "/d/Omnigent.app/Contents/MacOS/Omnigent", "files": files},
        ]
        self.assertEqual(coverage.hosted_files(listing), ["/p/Sources/App.swift"])

    def test_hosted_summary_counts_executable_lines_outside_markers(self):
        source = "let a = 1\nlet b = 2\n// coverage:off VM flow testDrag\nc\n// coverage:on\n"
        archive = {
            "/p/Sources/App.swift": [
                {"line": 1, "isExecutable": True, "executionCount": 4},
                {"line": 2, "isExecutable": True, "executionCount": 0},
                {"line": 3, "isExecutable": False},
                {"line": 4, "isExecutable": True, "executionCount": 0},
            ]
        }
        rows = coverage.summarize_hosted(
            ["/p/Sources/App.swift", "/p/Sources/Unbuilt.swift"],
            archive,
            read_source=lambda _path: source,
        )
        self.assertEqual(
            rows,
            [
                ("/p/Sources/App.swift", 1, 2, [2], [(3, 5, "VM flow testDrag")]),
                ("/p/Sources/Unbuilt.swift", 0, 0, [], [(3, 5, "VM flow testDrag")]),
            ],
        )

    def test_hosted_summary_names_the_file_with_a_bad_marker(self):
        with self.assertRaisesRegex(SystemExit, "App.swift: line 1"):
            coverage.summarize_hosted(
                ["/p/Sources/App.swift"], {}, read_source=lambda _path: "// coverage:on\n"
            )


if __name__ == "__main__":
    unittest.main()
