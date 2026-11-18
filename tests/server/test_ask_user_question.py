"""Unit tests for the shared AskUserQuestion helpers: the card's questions and Claude's answers."""

from typing import Any

import pytest

from omnigent.server.ask_user_question import (
    answered_ask_user_question_input,
    structured_ask_user_question,
)


def test_basic_question_with_dict_options() -> None:
    out = structured_ask_user_question(
        {
            "questions": [
                {
                    "question": "Which environment?",
                    "options": [
                        {"label": "dev", "description": "development"},
                        {"label": "prod", "preview": "kubectl get pods -n prod"},
                    ],
                }
            ]
        }
    )
    assert out == {
        "questions": [
            {
                "question": "Which environment?",
                "options": [
                    {"label": "dev", "description": "development"},
                    {"label": "prod", "preview": "kubectl get pods -n prod"},
                ],
                "multiSelect": False,
                # Claude's picker takes a note on a single choice with previews.
                "acceptsNotes": True,
            }
        ]
    }


def test_string_options_and_multiselect_and_header() -> None:
    out = structured_ask_user_question(
        {
            "questions": [
                {
                    "question": "Pick regions",
                    "header": "Regions",
                    "multiSelect": True,
                    "options": ["us-east", "eu-west"],
                }
            ]
        }
    )
    assert out is not None
    q = out["questions"][0]
    assert q["multiSelect"] is True
    assert q["header"] == "Regions"
    assert q["options"] == [{"label": "us-east"}, {"label": "eu-west"}]


def test_returns_none_when_not_a_dict() -> None:
    assert structured_ask_user_question("AskUserQuestion(...)") is None


def test_returns_none_when_no_questions() -> None:
    assert structured_ask_user_question({"questions": []}) is None
    assert structured_ask_user_question({}) is None


def test_skips_question_with_no_valid_options() -> None:
    # A question whose options are all malformed drops out; if that
    # leaves no questions, the whole payload is None (binary fallback).
    assert (
        structured_ask_user_question(
            {"questions": [{"question": "Q", "options": [{"no_label": 1}]}]}
        )
        is None
    )


def test_keeps_valid_questions_alongside_invalid_ones() -> None:
    # One malformed question must not discard the usable ones next to it.
    out = structured_ask_user_question(
        {
            "questions": [
                {"question": "Broken", "options": [{"no_label": 1}]},
                {"question": "", "options": ["x"]},
                {"question": "Env?", "options": ["dev", "prod"]},
            ]
        }
    )
    assert out == {
        "questions": [
            {
                "question": "Env?",
                "options": [{"label": "dev"}, {"label": "prod"}],
                "multiSelect": False,
            }
        ]
    }


_LAYOUT = "Which layout?"
_PLATFORMS = "Which platforms?"


def _questions() -> dict[str, Any]:
    """A single choice with previews and a multi-select without them."""
    return {
        "questions": [
            {
                "question": _LAYOUT,
                "header": "Layout",
                "options": [
                    {"label": "Sidebar", "description": "Left", "preview": "[nav] | [body]"},
                    {"label": "Top bar", "description": "Top", "preview": "[nav]\n[body]"},
                ],
                "multiSelect": False,
            },
            {
                "question": _PLATFORMS,
                "header": "Platforms",
                "options": [
                    {"label": "Mac", "description": "Desktop"},
                    {"label": "iPhone", "description": "Phone"},
                ],
                "multiSelect": True,
            },
        ]
    }


def test_only_a_single_choice_with_previews_takes_notes() -> None:
    out = structured_ask_user_question(_questions())
    assert out is not None
    assert [question.get("acceptsNotes") for question in out["questions"]] == [True, None]


@pytest.mark.parametrize(
    ("content", "meta", "answers", "annotations"),
    [
        # The chosen option's preview rides along; several choices join as Claude joins them.
        (
            {_LAYOUT: "Sidebar", _PLATFORMS: ["Mac", "iPhone"]},
            None,
            {_LAYOUT: "Sidebar", _PLATFORMS: "Mac, iPhone"},
            {_LAYOUT: {"preview": "[nav] | [body]"}},
        ),
        # A note is trimmed; a note on a question without previews is dropped.
        (
            {_LAYOUT: "Top bar", _PLATFORMS: ["Mac"]},
            {"notes": {_LAYOUT: "  Keep it light. ", _PLATFORMS: "Ignored"}},
            {_LAYOUT: "Top bar", _PLATFORMS: "Mac"},
            {_LAYOUT: {"preview": "[nav]\n[body]", "notes": "Keep it light."}},
        ),
        # A typed answer has no preview; its note still reaches Claude.
        (
            {_LAYOUT: "Tabs", _PLATFORMS: ["iPad"]},
            {"notes": {_LAYOUT: "Like Settings."}},
            {_LAYOUT: "Tabs", _PLATFORMS: "iPad"},
            {_LAYOUT: {"notes": "Like Settings."}},
        ),
        # Nothing to annotate, and malformed notes: no ``annotations`` at all.
        (
            {_LAYOUT: "Tabs", _PLATFORMS: ["Mac"]},
            {"notes": ["not", "a", "map"]},
            {_LAYOUT: "Tabs", _PLATFORMS: "Mac"},
            None,
        ),
    ],
)
def test_answered_input_carries_answers_and_annotations(
    content: dict[str, Any],
    meta: dict[str, Any] | None,
    answers: dict[str, Any],
    annotations: dict[str, Any] | None,
) -> None:
    tool_input = _questions()
    out = answered_ask_user_question_input(tool_input, content, meta)
    assert out["questions"] == tool_input["questions"]
    assert out["answers"] == answers
    assert out.get("annotations") == annotations
