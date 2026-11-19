"""The large-data seed plans stable, varied sessions and transcripts the server accepts."""

import collections
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "seed_large_fixtures", Path(__file__).with_name("seed-large-fixtures.py")
)
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)


class PlanTests(unittest.TestCase):
    def test_plan_is_stable_and_unique(self):
        first = seed.plan_sessions(320, 3, 500)
        self.assertEqual(first, seed.plan_sessions(320, 3, 500))
        self.assertEqual(len(first), 323)
        self.assertEqual(len({plan.session_id for plan in first}), 323)
        self.assertTrue(all(len(plan.session_id) == 32 for plan in first))

    def test_long_sessions_come_first_and_reach_the_turn_count(self):
        plans = seed.plan_sessions(10, 3, 500)
        self.assertEqual([plan.long for plan in plans[:4]], [True, True, True, False])
        self.assertEqual([plan.turns for plan in plans[:3]], [500, 650, 800])

    def test_short_sessions_span_projects_unfiled_and_two_months(self):
        plans = seed.plan_sessions(320, 0, 500)
        projects = {plan.project for plan in plans}
        self.assertEqual(projects, {None, *range(len(seed.PROJECT_NAMES))})
        self.assertGreater(max(plan.age_seconds for plan in plans), 59 * seed.DAY)


class SidebarPlanTests(unittest.TestCase):
    def test_sidebar_state_spreads_past_the_first_page(self):
        plans = seed.plan_sidebar(seed.plan_sessions(400, 0, 500), 12, 160, 15, 40)
        self.assertEqual(sum(plan.archived for plan in plans), 160)
        self.assertEqual(sum(plan.pinned for plan in plans), 12)
        self.assertFalse(any(plan.pinned and plan.archived for plan in plans))
        families = collections.Counter(plan.family for plan in plans if plan.family)
        self.assertEqual(len(families), 15)
        self.assertEqual(set(families.values()), {3})
        self.assertEqual(sum(plan.owner == "teammate" for plan in plans), 40)
        self.assertEqual(len({plan.session_id for plan in plans}), len(plans))
        older = sorted(plans, key=lambda plan: plan.age_seconds)[50:]
        self.assertTrue(any(plan.pinned for plan in older))
        self.assertTrue(any(plan.archived for plan in older))

    def test_no_sidebar_state_leaves_the_plan_alone(self):
        plans = seed.plan_sessions(30, 1, 300)
        self.assertEqual(seed.plan_sidebar(plans, 0, 0, 0, 0), plans)


class TranscriptTests(unittest.TestCase):
    def test_long_turns_cover_every_rich_block(self):
        text = "\n".join(seed.assistant_text(turn) for turn in range(1, 71))
        for marker in ("```swift", "| Step |", "- [x]", "$$", "```mermaid", "\\("):
            self.assertIn(marker, text)

    def test_tool_calls_pair_with_their_outputs(self):
        items = [item for turn in range(1, 30) for item in seed.turn_items("s", turn, "mock")]
        calls = {item.data["call_id"] for item in items if item.type == "function_call"}
        outputs = {item.data["call_id"] for item in items if item.type == "function_call_output"}
        self.assertEqual(calls, outputs)
        self.assertGreater(len(calls), 20)
        self.assertEqual(len({item.stable_id for item in items}), len(items))

    def test_items_validate_as_server_entities(self):
        from omnigent.entities import (
            FunctionCallData,
            FunctionCallOutputData,
            MessageData,
            NewConversationItem,
            ReasoningData,
        )

        models = {
            "message": MessageData,
            "reasoning": ReasoningData,
            "function_call": FunctionCallData,
            "function_call_output": FunctionCallOutputData,
        }
        for spec_item in seed.turn_items("s", 12, "mock") + seed.short_turn_items("s", 1, "mock"):
            NewConversationItem(
                type=spec_item.type,
                response_id=spec_item.response_id,
                data=models[spec_item.type](**spec_item.data),
                stable_id=spec_item.stable_id,
            )


if __name__ == "__main__":
    unittest.main()
