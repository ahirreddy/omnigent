"""ios_perf.py reads the frame monitor's log lines and ``ps`` times into numbers."""

import importlib.util
import sys
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("ios_perf", Path(__file__).with_name("ios_perf.py"))
ios_perf = importlib.util.module_from_spec(spec)
sys.modules["ios_perf"] = ios_perf
spec.loader.exec_module(ios_perf)

LINE = (
    "2026-11-05 03:00:56.343 Df Omnigent[93840:15b0bca] [ai.omnigent.perf:frames] interval "
    "marked: fps=57.4 frames=217 hitch=44.1ms/s dropped=11 >8.3ms=217 >16.7ms=4 >33ms=3 "
    "worst=77.3ms refresh=16.7ms renders=screen:5,transcript:6"
)


class ParseTests(unittest.TestCase):
    def test_reads_every_number_and_render_count(self):
        stats = ios_perf.parse_stats(LINE)
        self.assertEqual(stats["fps"], 57.4)
        self.assertEqual(stats["hitch"], 44.1)
        self.assertEqual(stats[">16.7ms"], 4)
        self.assertEqual(stats["worst"], 77.3)
        self.assertEqual(stats["renders.screen"], 5)
        self.assertEqual(stats["renders.transcript"], 6)

    def test_ignores_lines_without_stats(self):
        self.assertIsNone(ios_perf.parse_stats("begin marked"))

    def test_ps_times(self):
        self.assertEqual(ios_perf.ps_cpu_ms("0:01.50"), 1500)
        self.assertEqual(ios_perf.ps_cpu_ms("1:02:03"), 3723000)

    def test_long_session_ids_match_the_seed(self):
        self.assertEqual(ios_perf.long_session(1), "0579820c2e81aae86478785be21acbdf")


if __name__ == "__main__":
    unittest.main()
