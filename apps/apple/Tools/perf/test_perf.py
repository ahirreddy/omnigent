"""perf.py reads the hitch monitor's log and sample reports into the numbers it reports."""

import importlib.util
import sys
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("perf", Path(__file__).with_name("perf.py"))
perf = importlib.util.module_from_spec(spec)
sys.modules["perf"] = perf
spec.loader.exec_module(perf)

seed_spec = importlib.util.spec_from_file_location(
    "seed_large_fixtures", Path(__file__).parents[1] / "seed-large-fixtures.py"
)
seed = importlib.util.module_from_spec(seed_spec)
seed_spec.loader.exec_module(seed)

breakdown_spec = importlib.util.spec_from_file_location(
    "sample_breakdown", Path(__file__).with_name("sample-breakdown.py")
)
breakdown = importlib.util.module_from_spec(breakdown_spec)
breakdown_spec.loader.exec_module(breakdown)

LOG = """# start 900
# alive 1000
1000 50.0
1100 20.0
1200 150.0
# alive 1400
3000 40.0
# alive 4200
"""


class LogTests(unittest.TestCase):
    def test_counts_waits_inside_the_window(self):
        numbers = perf.parse_log(LOG, 1000, 2000).numbers
        self.assertEqual(numbers["hitches"], 2)
        self.assertEqual(numbers["hangs"], 1)
        self.assertEqual(numbers["worst_ms"], 150.0)
        self.assertEqual(numbers["blocked_ms"], 200.0)

    def test_settles_at_the_last_hitch_before_a_quiet_second(self):
        self.assertEqual(perf.settle_time(LOG, 1000), 350.0)
        self.assertEqual(perf.quiet_since(LOG, 1000), 4200 - 1350)

    def test_an_open_stall_is_not_quiet(self):
        self.assertEqual(perf.quiet_since(LOG + "# stalled 4300\n", 1000), 0.0)

    def test_only_the_running_app_lines_count(self):
        earlier = "# start 1\n1000 500.0\n"
        self.assertEqual(perf.parse_log(earlier + LOG, 1000, 2000).numbers["worst_ms"], 150.0)


FRAMES = """# start 900
# frames 1250 15 16.67
1300 50.0
# frames 1500 12 16.67
1600 25.0
# frames 1750 15 16.67
# frames 2000 15 16.67
"""


class FrameTests(unittest.TestCase):
    def test_counts_frames_and_long_ones_inside_the_window(self):
        numbers = perf.parse_frames(FRAMES, 1000, 2000).numbers
        # The windows ending at 1250 through 2000: 57 frames over a second.
        self.assertEqual(numbers["fps"], 57)
        self.assertEqual(numbers["long_frames"], 2)
        self.assertEqual(numbers["dropped"], 2)
        self.assertAlmostEqual(numbers["hitch_ms_per_s"], 50 + 25 - 2 * 16.67)
        self.assertEqual(numbers["worst_frame_ms"], 50.0)

    def test_driver_steps_take_their_frames(self):
        self.assertAlmostEqual(perf.step_seconds("scroll 0.5 0.5 -60 59"), 1.0)
        self.assertAlmostEqual(perf.step_seconds("wait 700"), 0.7)
        self.assertAlmostEqual(perf.step_seconds("resize 10 10 30"), 0.5)
        # 8 gesture frames, 143 tail frames from 60 pt down to half a point, the end, a report.
        self.assertAlmostEqual(perf.step_seconds("swipe 0.5 0.5 60 8"), 153 / 60)

    def test_reads_the_scrolls_inside_the_window(self):
        text = "# start 900\n# scrolled 1500 6196 880 11277\n# frames 1750 15 16.67\n"
        self.assertEqual(perf.scrolled(text, 1000, 2000), [(6196.0, 880.0, 11277.0)])
        self.assertEqual(perf.scrolled(text, 1600, 2000), [])


BUSY = """# start 900
1000.0 2.00
1100.0 9.00
1200.5 20.00
1300.0 4.00
2500.0 30.00
"""


class BusyTests(unittest.TestCase):
    def test_counts_run_loop_passes_over_a_frame(self):
        numbers = perf.parse_busy(BUSY, 1000, 2000).numbers
        self.assertEqual(numbers["passes"], 4)
        self.assertEqual(numbers["busy_ms"], 35.0)
        self.assertEqual(numbers["over_8ms"], 2)
        self.assertEqual(numbers["over_8ms_pct"], 50.0)
        self.assertEqual(numbers["over_16ms"], 1)
        self.assertEqual(numbers["p50_ms"], 9.0)
        self.assertEqual(numbers["max_ms"], 20.0)

    def test_an_empty_window_has_no_passes(self):
        numbers = perf.parse_busy(BUSY, 3000, 4000).numbers
        self.assertEqual(numbers["max_ms"], 0.0)
        self.assertEqual(numbers["over_8ms_pct"], 0.0)


class VariantTests(unittest.TestCase):
    def test_a_variant_is_a_name_and_its_launch_arguments(self):
        variant = perf.Variant.parse("textkit=-omnigent:message-text textkit")
        self.assertEqual(variant.name, "textkit")
        self.assertEqual(variant.args, ["-omnigent:message-text", "textkit"])
        self.assertEqual(perf.Variant.parse("base=").args, [])

    def test_a_variant_needs_a_name_and_an_equals_sign(self):
        for text in ("textkit", "=-a b"):
            with self.assertRaises(ValueError):
                perf.Variant.parse(text)


class SampleTests(unittest.TestCase):
    REPORT = """Call graph:
    10 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
    + 10 start  (in dyld) + 1  [0x1]
    +   6 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x2]
    +   4 Layout  (in SwiftUI) + 1  [0x3]
    +     4 measure  (in SwiftUI) + 1  [0x4]
    3 Thread_2
"""

    def test_busy_main_thread_samples_exclude_waits(self):
        self.assertEqual(perf.main_thread_busy(self.REPORT), (4, 10))

    BREAKDOWN = """Call graph:
    10 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
    + 10 main  (in Omnigent) + 1  [0x1]
    +   3 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x2]
    +   4 CA::Layer::display_if_needed(CA::Transaction*)  (in QuartzCore) + 1  [0x3]
    +   ! 3 CTLineCreateWithAttributedString  (in CoreText) + 1  [0x4]
    +   3 NSHostingView.layout()  (in SwiftUI) + 1  [0x5]
    +     2 SelectionOverlay.updateNSView(_:context:)  (in SwiftUI) + 1  [0x6]
    +     1 CTLineCreateWithAttributedString  (in CoreText) + 1  [0x7]
    3 Thread_2
"""

    def test_breakdown_files_each_sample_under_the_first_category_its_stack_matches(self):
        found = {}
        for stack, count in breakdown.stacks(breakdown.main_thread(self.BREAKDOWN)).items():
            name, _ = breakdown.category(stack)
            found[name] = found.get(name, 0) + count
        self.assertEqual(
            found,
            {
                "waiting": 3,
                # Typesetting inside drawing is drawing; outside it, text layout.
                "drawing layer contents (text drawn and typeset again)": 4,
                "AppKit views per text (selection overlays, link areas)": 2,
                "text layout and typesetting": 1,
            },
        )


class SessionTests(unittest.TestCase):
    def test_long_session_ids_match_the_seed(self):
        plans = seed.plan_sessions(0, 2, 500)
        self.assertEqual(
            [perf.long_session(0), perf.long_session(1)], [p.session_id for p in plans]
        )

    def test_the_first_answer_link_names_the_seeded_response(self):
        session = perf.long_session(0)
        self.assertTrue(
            perf.first_answer_link(session).endswith(
                f"/c/{session}?message=resp_{seed.fixed_id(session, 'resp', 1)}"
            )
        )


if __name__ == "__main__":
    unittest.main()
