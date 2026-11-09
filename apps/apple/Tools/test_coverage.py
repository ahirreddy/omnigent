"""The coverage report reads llvm-cov's segments correctly."""

import importlib.util
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

    def test_summary_leaves_out_the_gallery(self):
        document = {"data": [{"files": [self.entry("/p/Sources/Gallery/Sample.swift", [])]}]}
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


if __name__ == "__main__":
    unittest.main()
