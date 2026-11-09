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

    def test_summary_keeps_only_files_under_sources(self):
        document = {
            "data": [
                {
                    "files": [
                        {
                            "filename": "/p/Sources/A.swift",
                            "summary": {"lines": {"covered": 1, "count": 2}},
                            "segments": [],
                        },
                        {
                            "filename": "/p/Tests/B.swift",
                            "summary": {"lines": {"covered": 1, "count": 1}},
                            "segments": [],
                        },
                    ]
                }
            ]
        }
        self.assertEqual(
            coverage.summarize(document, Path("/p/Sources")), [("/p/Sources/A.swift", 1, 2, [])]
        )


if __name__ == "__main__":
    unittest.main()
