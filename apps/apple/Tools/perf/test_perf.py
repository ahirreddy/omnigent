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


class SessionTests(unittest.TestCase):
    def test_long_session_ids_match_the_seed(self):
        plans = seed.plan_sessions(0, 2, 500)
        self.assertEqual(
            [perf.long_session(0), perf.long_session(1)], [p.session_id for p in plans]
        )


if __name__ == "__main__":
    unittest.main()
