"""Tests for the Codex elicitation protocol adapters.

These are pure-function tests — no HTTP or runtime needed.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from omnigent.errors import OmnigentError
from omnigent.server.routes._codex_elicitation import (
    _CODEX_ELICITATION_ADAPTERS,
    _codex_command_preview,
    _codex_mcp_elicitation_response,
    _codex_mcp_persist_modes,
    _execpolicy_amendment,
    _json_preview,
    _string_list_answer,
    parse_codex_elicitation_request,
)
from omnigent.server.schemas import ElicitationResult

# Shared with omnigent-core's `decisions/codex_tests.rs`: each file holds one Codex request,
# the elicitation the server publishes for it, an answer the app posts, and the result Codex
# receives.
_CODEX_DECISION_FIXTURES = sorted(
    (Path(__file__).resolve().parents[3] / "client-core" / "fixtures" / "decisions").glob(
        "Codex--*.json"
    )
)


def _codex_fixture(path: Path) -> dict[str, Any]:
    """
    Load one shared Codex decision fixture.

    :param path: Fixture file, e.g. ``Codex--FileChangeRequestApproval.json``.
    :returns: The fixture's ``codex``, ``elicitation``, ``answer`` and
        ``codex_result`` entries.
    """
    return json.loads(path.read_text(encoding="utf-8"))


class TestCodexDecisionFixtures:
    """Every Codex request kind maps to the elicitation the native app reads, and back."""

    def test_every_codex_request_method_has_a_fixture(self) -> None:
        methods = {_codex_fixture(path)["codex"]["method"] for path in _CODEX_DECISION_FIXTURES}
        assert methods == set(_CODEX_ELICITATION_ADAPTERS)

    @pytest.mark.parametrize("path", _CODEX_DECISION_FIXTURES, ids=lambda path: path.stem)
    def test_request_publishes_the_fixture_elicitation(self, path: Path) -> None:
        fixture = _codex_fixture(path)

        request = parse_codex_elicitation_request(fixture["codex"])

        published = {
            key: value
            for key, value in request.params.model_dump(mode="json").items()
            if value is not None
        }
        assert published.pop("content_preview") == _json_preview(fixture["codex"]["params"])
        assert published == fixture["elicitation"]["params"]

    @pytest.mark.parametrize("path", _CODEX_DECISION_FIXTURES, ids=lambda path: path.stem)
    def test_answer_becomes_the_fixture_codex_result(self, path: Path) -> None:
        fixture = _codex_fixture(path)
        request = parse_codex_elicitation_request(fixture["codex"])

        result = request.build_response(ElicitationResult.model_validate(fixture["answer"]))

        assert result == fixture["codex_result"]


# ── parse_codex_elicitation_request ──────────────────────────────────


class TestParseCodexElicitationRequest:
    """Tests for the top-level request parser."""

    def test_missing_method_raises(self) -> None:
        with pytest.raises(OmnigentError, match="non-empty method"):
            parse_codex_elicitation_request({"id": 1, "params": {}})

    def test_empty_method_raises(self) -> None:
        with pytest.raises(OmnigentError, match="non-empty method"):
            parse_codex_elicitation_request({"id": 1, "method": "", "params": {}})

    def test_non_dict_params_raises(self) -> None:
        with pytest.raises(OmnigentError, match="params must be an object"):
            parse_codex_elicitation_request(
                {"id": 1, "method": "mcpServer/elicitation/request", "params": "bad"}
            )

    def test_missing_id_raises(self) -> None:
        with pytest.raises(OmnigentError, match="string or integer id"):
            parse_codex_elicitation_request(
                {"method": "mcpServer/elicitation/request", "params": {}}
            )

    def test_unsupported_method_raises(self) -> None:
        with pytest.raises(OmnigentError, match="Unsupported"):
            parse_codex_elicitation_request({"id": 1, "method": "unknown/method", "params": {}})

    def test_valid_mcp_form_request(self) -> None:
        req = parse_codex_elicitation_request(
            {
                "id": 1,
                "method": "mcpServer/elicitation/request",
                "params": {
                    "mode": "form",
                    "message": "Need input",
                    "requestedSchema": {"type": "object"},
                },
            }
        )
        assert req.method == "mcpServer/elicitation/request"
        assert req.params.mode == "form"

    def test_valid_command_approval(self) -> None:
        req = parse_codex_elicitation_request(
            {
                "id": 2,
                "method": "item/commandExecution/requestApproval",
                "params": {"command": "npm test"},
            }
        )
        assert req.method == "item/commandExecution/requestApproval"


# ── Codex MCP approval persistence ───────────────────────────────────


class TestCodexMcpApprovalPersistence:
    """Tests for Codex's session and durable MCP approval choices."""

    @pytest.mark.parametrize("mode", ["session", "always"])
    def test_returns_advertised_persistence_mode(self, mode: str) -> None:
        result = ElicitationResult.model_validate({"action": "accept", "_meta": {"persist": mode}})

        response = _codex_mcp_elicitation_response(
            result,
            "mcpServer/elicitation/request",
            {
                "_meta": {
                    "codex_approval_kind": "mcp_tool_call",
                    "persist": ["session", "always"],
                }
            },
        )

        assert response == {
            "action": "accept",
            "content": None,
            "_meta": {"persist": mode},
        }

    def test_rejects_unadvertised_persistence_mode(self) -> None:
        result = ElicitationResult.model_validate(
            {"action": "accept", "_meta": {"persist": "always"}}
        )

        with pytest.raises(OmnigentError, match="was not advertised"):
            _codex_mcp_elicitation_response(
                result,
                "mcpServer/elicitation/request",
                {
                    "_meta": {
                        "codex_approval_kind": "mcp_tool_call",
                        "persist": ["session"],
                    }
                },
            )

    def test_ignores_malformed_advertised_modes(self) -> None:
        params = {
            "_meta": {
                "codex_approval_kind": "mcp_tool_call",
                "persist": ["session", {"unexpected": "object"}, None],
            }
        }

        assert _codex_mcp_persist_modes(params) == {"session"}


# ── _string_list_answer ──────────────────────────────────────────────


class TestStringListAnswer:
    """Tests for answer normalization."""

    def test_string_input(self) -> None:
        assert _string_list_answer("React") == ["React"]

    def test_empty_string(self) -> None:
        assert _string_list_answer("") == []

    def test_list_input(self) -> None:
        assert _string_list_answer(["a", "b"]) == ["a", "b"]

    def test_list_with_non_strings(self) -> None:
        assert _string_list_answer(["a", 123, "b"]) == ["a", "b"]

    def test_none_input(self) -> None:
        assert _string_list_answer(None) == []

    def test_numeric_input(self) -> None:
        assert _string_list_answer(42) == ["42"]


# ── _codex_command_preview ───────────────────────────────────────────


class TestCodexCommandPreview:
    """Tests for command preview extraction."""

    def test_string_command(self) -> None:
        assert _codex_command_preview({"command": "npm test"}) == "npm test"

    def test_list_command(self) -> None:
        assert _codex_command_preview({"command": ["npm", "test"]}) == "npm test"

    def test_empty_command(self) -> None:
        assert _codex_command_preview({"command": ""}) is None

    def test_missing_command(self) -> None:
        assert _codex_command_preview({}) is None


# ── _json_preview ────────────────────────────────────────────────────


class TestJsonPreview:
    """Tests for the bounded preview function."""

    def test_simple_object(self) -> None:
        result = _json_preview({"key": "value"})
        assert '"key"' in result

    def test_truncated(self) -> None:
        big = {"k": "x" * 2000}
        result = _json_preview(big)
        assert len(result) <= 1024


# ── _execpolicy_amendment ────────────────────────────────────────────


class TestExecpolicyAmendment:
    """Tests for execpolicy amendment validation."""

    def test_none_returns_none(self) -> None:
        assert _execpolicy_amendment(None) is None

    def test_valid_list(self) -> None:
        assert _execpolicy_amendment(["pytest", "-v"]) == ["pytest", "-v"]

    def test_empty_list_raises(self) -> None:
        with pytest.raises(OmnigentError, match="non-empty list"):
            _execpolicy_amendment([])

    def test_non_list_raises(self) -> None:
        with pytest.raises(OmnigentError, match="non-empty list"):
            _execpolicy_amendment("pytest")

    def test_list_with_non_strings_raises(self) -> None:
        with pytest.raises(OmnigentError, match="non-empty list"):
            _execpolicy_amendment(["pytest", 42])
