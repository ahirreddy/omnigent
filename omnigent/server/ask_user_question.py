"""Structured extraction of Claude's AskUserQuestion tool input, and the answered input.

Shared by the server permission/elicitation routes and the claude-sdk
elicitation bridge (``runtime/harnesses/_executor_adapter.py``). Both ship
the returned structure to the UI as the ``ask_user_question`` extra on
``ElicitationRequestParams`` so the front-end renders an interactive option
form instead of the truncated ``content_preview`` blob.

Kept dependency-free (stdlib/typing only) so runtime code can import it
without pulling in server-route modules.
"""

from __future__ import annotations

from typing import Any


def structured_ask_user_question(tool_input: Any) -> dict[str, Any] | None:
    """Build a structured AskUserQuestion payload for elicitation extras.

    The returned shape is the same one the UI's
    :file:`web/src/lib/askUserQuestion.ts` consumes, so the front-end can
    render an interactive option form directly.

    :param tool_input: The ``tool_input`` field from the tool call.
    :returns: ``{"questions": [...]}`` on success, or ``None`` when the
        input doesn't carry a usable AskUserQuestion shape (no questions,
        malformed options, etc.) — caller falls back to the binary
        preview-only render.
    """
    if not isinstance(tool_input, dict):
        return None
    questions_raw = tool_input.get("questions")
    if not isinstance(questions_raw, list) or not questions_raw:
        return None
    questions: list[dict[str, Any]] = []
    for entry in questions_raw:
        if not isinstance(entry, dict):
            continue
        question_text = entry.get("question")
        if not isinstance(question_text, str) or not question_text:
            continue
        options_raw = entry.get("options")
        if not isinstance(options_raw, list):
            continue
        options: list[dict[str, Any]] = []
        for opt in options_raw:
            if isinstance(opt, dict):
                label = opt.get("label")
                if not isinstance(label, str) or not label:
                    continue
                option: dict[str, Any] = {"label": label}
                description = opt.get("description")
                if isinstance(description, str) and description:
                    option["description"] = description
                # Optional per-option preview snippet; pass through verbatim for the UI.
                preview = opt.get("preview")
                if isinstance(preview, str) and preview:
                    option["preview"] = preview
                options.append(option)
            elif isinstance(opt, str) and opt:
                options.append({"label": opt})
        if not options:
            continue
        question: dict[str, Any] = {
            "question": question_text,
            "options": options,
            "multiSelect": entry.get("multiSelect") is True,
        }
        header = entry.get("header")
        if isinstance(header, str) and header:
            question["header"] = header
        if _takes_notes(question):
            question["acceptsNotes"] = True
        questions.append(question)
    if not questions:
        return None
    return {"questions": questions}


def _takes_notes(question: dict[str, Any]) -> bool:
    """Whether Claude's picker lets the user note an answer: a single choice with previews."""
    options = question.get("options")
    return (
        question.get("multiSelect") is not True
        and isinstance(options, list)
        and any(isinstance(option, dict) and option.get("preview") for option in options)
    )


def _answer_text(value: Any) -> Any:
    """One answer as Claude's picker reports it: several choices joined by ``", "``."""
    if isinstance(value, list) and all(isinstance(choice, str) for choice in value):
        return ", ".join(value)
    return value


def _chosen_preview(question: dict[str, Any], answer: Any) -> str | None:
    """The preview of the option ``answer`` names, if it has one."""
    for option in question.get("options") or []:
        if isinstance(option, dict) and option.get("label") == answer:
            preview = option.get("preview")
            return preview if isinstance(preview, str) and preview else None
    return None


def answered_ask_user_question_input(
    tool_input: dict[str, Any],
    content: dict[str, Any],
    meta: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """
    Claude's ``AskUserQuestion`` input with the user's answers, as Claude's picker returns it.

    ``answers`` maps each question to its answer text, a multi-select answer
    joined by ``", "``. ``annotations`` carries, for a question with previews,
    the chosen option's preview and the user's note from ``_meta.notes``;
    questions with neither are left out, and so is an empty ``annotations``.

    :param tool_input: The tool input Claude asked with, e.g.
        ``{"questions": [{"question": "Which layout?", ...}]}``.
    :param content: The accepted form, keyed by question text, e.g.
        ``{"Which layout?": "Sidebar"}``.
    :param meta: The answer's ``_meta``, e.g.
        ``{"notes": {"Which layout?": "Keep it collapsible."}}``.
    :returns: ``tool_input`` with ``answers`` and, when any, ``annotations``.
    """
    answers = {key: _answer_text(value) for key, value in content.items()}
    raw_notes = meta.get("notes") if isinstance(meta, dict) else None
    notes = raw_notes if isinstance(raw_notes, dict) else {}
    annotations: dict[str, dict[str, str]] = {}
    questions = tool_input.get("questions")
    for question in questions if isinstance(questions, list) else []:
        if not isinstance(question, dict) or not _takes_notes(question):
            continue
        text = question.get("question")
        if not isinstance(text, str):
            continue
        annotation: dict[str, str] = {}
        preview = _chosen_preview(question, answers.get(text))
        if preview is not None:
            annotation["preview"] = preview
        note = notes.get(text)
        if isinstance(note, str) and note.strip():
            annotation["notes"] = note.strip()
        if annotation:
            annotations[text] = annotation
    answered: dict[str, Any] = {**tool_input, "answers": answers}
    if annotations:
        answered["annotations"] = annotations
    return answered
