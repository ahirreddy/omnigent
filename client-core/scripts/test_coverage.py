"""The Rust coverage report counts the right lines."""

import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("coverage", Path(__file__).with_name("coverage.py"))
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)


class LcovTests(unittest.TestCase):
    def test_any_hit_in_any_binary_covers_a_line(self):
        text = "SF:/a.rs\nDA:1,0\nDA:2,3\nend_of_record\nSF:/a.rs\nDA:1,4\nDA:2,0\nend_of_record\n"
        self.assertEqual(coverage.parse_lcov(text), {"/a.rs": {1: 4, 2: 3}})

    def test_ranges_compress_runs(self):
        self.assertEqual(coverage.line_ranges([1, 2, 3, 7, 9, 10]), ["1-3", "7", "9-10"])
        self.assertEqual(coverage.line_ranges([]), [])


class TestModuleTests(unittest.TestCase):
    def test_finds_the_inline_module_past_multi_line_attributes(self):
        source = "fn a() {}\n#[cfg(test)]\n#[allow(\n    clippy::x\n)]\nmod tests {\n}\n"
        self.assertEqual(coverage.test_module_start(source), 2)

    def test_a_module_in_its_own_file_is_not_a_trailing_module(self):
        source = "#[cfg(test)]\nmod tests;\nfn a() {}\n"
        self.assertIsNone(coverage.test_module_start(source))

    def test_a_test_only_item_is_not_a_module(self):
        self.assertIsNone(coverage.test_module_start("#[cfg(test)]\nfn helper() {}\n"))

    def test_finds_a_crate_visible_module(self):
        self.assertEqual(coverage.test_module_start("#[cfg(test)]\npub(crate) mod a {\n"), 1)


class MarkerTests(unittest.TestCase):
    def test_a_marked_range_is_excluded_with_its_reason(self):
        source = "a\n    // coverage:off needs a real keychain\nb\n    // coverage:on\nc\n"
        excluded, reasons = coverage.excluded_lines(source)
        self.assertEqual(excluded, {2, 3, 4})
        self.assertEqual(reasons, [(2, 4, "needs a real keychain")])

    def test_invalid_markers_are_rejected(self):
        invalid = {
            "no reason": "// coverage:off\n// coverage:on\n",
            "never closed": "// coverage:off why\n",
            "never opened": "// coverage:on\n",
            "nested": "// coverage:off why\n// coverage:off why\n// coverage:on\n",
        }
        for name, source in invalid.items():
            with self.subTest(name), self.assertRaises(ValueError):
                coverage.excluded_lines(source)

    def test_a_marker_after_code_on_the_line_is_not_a_marker(self):
        self.assertEqual(coverage.excluded_lines("x(); // coverage:off why\n"), (set(), []))


class SummaryTests(unittest.TestCase):
    PREFIX = "/w/client-core/crates/"

    def summarize(self, files, source=""):
        return coverage.summarize(files, read_source=lambda _path: source)

    def test_only_workspace_product_files_count(self):
        files = {
            f"{self.PREFIX}core/src/a.rs": {1: 1},
            f"{self.PREFIX}core/src/a_tests.rs": {1: 0},
            f"{self.PREFIX}core/src/testing.rs": {1: 0},
            f"{self.PREFIX}core/tests/flow.rs": {1: 0},
            f"{self.PREFIX}uniffi-bindgen/src/main.rs": {1: 0},
            "/elsewhere/lib.rs": {1: 0},
        }
        self.assertEqual(self.summarize(files), [("core/src/a.rs", {1: 1}, [])])

    def test_trailing_tests_and_marked_lines_do_not_count(self):
        source = "\n".join(
            ["fn a() {}", "// coverage:off why", "b", "// coverage:on", "#[cfg(test)]", "mod t {"]
        )
        files = {f"{self.PREFIX}core/src/a.rs": {1: 1, 3: 0, 5: 0, 6: 0}}
        self.assertEqual(
            self.summarize(files, source), [("core/src/a.rs", {1: 1}, [(2, 4, "why")])]
        )

    def test_a_bad_marker_names_its_file(self):
        with self.assertRaisesRegex(ValueError, "core/src/a.rs: line 1"):
            self.summarize({f"{self.PREFIX}core/src/a.rs": {1: 1}}, "// coverage:on")

    def test_totals_and_listing_put_the_worst_file_first(self):
        rows = [
            ("a/src/x.rs", {1: 1, 2: 0}, []),
            ("a/src/y.rs", {1: 0, 2: 0, 3: 0, 5: 0}, []),
            ("b/src/z.rs", {1: 1}, []),
        ]
        self.assertEqual(coverage.crate_totals(rows), {"a": (6, 5), "b": (1, 0)})
        self.assertEqual(
            coverage.uncovered_listing(rows),
            ["    4/    4 a/src/y.rs: 1-3,5", "    1/    2 a/src/x.rs: 2"],
        )


class UnmeasuredTests(unittest.TestCase):
    def test_a_crate_missing_empty_or_never_reached_is_unmeasured(self):
        totals = {"good": (2, 1), "empty": (0, 0), "dark": (3, 3)}
        expected = {"good", "empty", "dark", "absent"}
        self.assertEqual(coverage.unmeasured_crates(totals, expected), ["absent", "dark", "empty"])

    def test_only_expected_crates_are_checked(self):
        self.assertEqual(coverage.unmeasured_crates({"dark": (3, 3)}, set()), [])


class CargoTests(unittest.TestCase):
    def test_only_test_binaries_are_objects(self):
        messages = "\n".join(
            [
                "not json",
                '{"reason":"compiler-artifact","executable":"/t/a","profile":{"test":true}}',
                '{"reason":"compiler-artifact","executable":"/t/b","profile":{"test":false}}',
                '{"reason":"compiler-artifact","executable":null,"profile":{"test":true}}',
                '{"reason":"build-finished"}',
            ]
        )
        self.assertEqual(coverage.test_executables(messages), ["/t/a"])

    def test_excluded_crates_are_not_built(self):
        arguments = coverage.cargo_test_arguments(4, "host-triple")
        self.assertEqual(arguments[arguments.index("--exclude") + 1], "uniffi-bindgen")
        self.assertEqual(arguments[arguments.index("-j") + 1], "4")

    def test_proc_macros_stay_uninstrumented_through_an_explicit_target(self):
        arguments = coverage.cargo_test_arguments(4, "host-triple")
        self.assertEqual(arguments[arguments.index("--target") + 1], "host-triple")


if __name__ == "__main__":
    unittest.main()
