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

    def test_reads_run_loop_passes_and_cpu(self):
        stats = ios_perf.parse_stats(
            "interval marked: fps=60.0 frames=6 hitch=0.0ms/s dropped=0 >8.3ms=0 >16.7ms=0 "
            ">33ms=0 worst=16.7ms refresh=16.7ms cpu=412ms loop.passes=380 loop.busy=402.5ms "
            "loop.p50=0.4ms loop.p95=3.1ms loop.p99=9.8ms loop.>8.3ms=5 loop.>16.7ms=1 "
            "loop.worst=21.0ms renders=transcript:2"
        )
        self.assertEqual(stats["cpu"], 412)
        self.assertEqual(stats["loop.p95"], 3.1)
        self.assertEqual(stats["loop.>8.3ms"], 5)
        self.assertEqual(stats["loop.worst"], 21.0)
        self.assertEqual(stats["renders.transcript"], 2)
        self.assertIn("loop.p99=9.8", ios_perf.format_numbers(stats))

    def test_render_names_may_have_spaces(self):
        stats = ios_perf.parse_stats(
            "interval marked: fps=60.0 worst=16.7ms renders=composer:9,session row:6,tab:3"
        )
        self.assertEqual(stats["renders.session row"], 6)
        self.assertEqual(stats["renders.tab"], 3)

    def test_keeps_the_numbers_before_a_cut_line(self):
        stats = ios_perf.parse_stats("interval marked: fps=60.0 worst=16.7ms renders=row:12,scr")
        self.assertEqual(stats["fps"], 60.0)
        self.assertEqual(stats["renders.row"], 12)
        self.assertNotIn("renders.scr", stats)

    def test_list_launch_arguments(self):
        self.assertEqual(ios_perf.list_args("stack"), ["-omnigent:transcript-list", "stack"])
        # The table pins SwiftUI rows, which the text rows replaced as its default.
        self.assertEqual(
            ios_perf.list_args("table"),
            ["-omnigent:transcript-list", "table", "-omnigent:message-text", "swiftui"],
        )
        self.assertEqual(
            ios_perf.list_args("text"),
            ["-omnigent:transcript-list", "table", "-omnigent:message-text", "textkit"],
        )

    def test_ignores_lines_without_stats(self):
        self.assertIsNone(ios_perf.parse_stats("begin marked"))

    def test_ps_times(self):
        self.assertEqual(ios_perf.ps_cpu_ms("0:01.50"), 1500)
        self.assertEqual(ios_perf.ps_cpu_ms("1:02:03"), 3723000)

    def test_long_session_ids_match_the_seed(self):
        self.assertEqual(ios_perf.long_session(1), "0579820c2e81aae86478785be21acbdf")


if __name__ == "__main__":
    unittest.main()
