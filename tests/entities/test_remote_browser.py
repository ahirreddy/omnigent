"""Remote browser rules shared by the server and runner relay hops."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from omnigent.entities.remote_browser import (
    browser_tab_resource,
    is_valid_browser_tab_id,
    validate_browser_profile_name,
    view_mode_allows_client_frame,
)

_FIXTURES = Path(__file__).resolve().parents[2] / "client-core" / "fixtures" / "remote_browser"
_CLIENT_MESSAGES = sorted((_FIXTURES / "messages" / "client_to_host").glob("*.json"))
# Client messages a view-only attach may send (section 5.4 gates).
_VIEW_ALLOWED = {
    "ack.json",
    "hello.json",
    "hello_v1_1.json",
    "keyframe_request.json",
    "ping.json",
    "settings_stats.json",
    "still_request.json",
    "visibility.json",
}


@pytest.mark.parametrize("path", _CLIENT_MESSAGES, ids=lambda path: path.name)
def test_view_mode_forwards_only_non_input_fixture_messages(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    assert view_mode_allows_client_frame(text) is (path.name in _VIEW_ALLOWED)


@pytest.mark.parametrize(
    "frame",
    [b"\x01\x02", "not json", "[1]", json.dumps({"type": "settings", "max_fps": 30})],
    ids=["binary", "invalid-json", "non-object", "settings-beyond-stats"],
)
def test_view_mode_drops_binary_malformed_and_owner_settings(frame: str | bytes) -> None:
    assert view_mode_allows_client_frame(frame) is False


@pytest.mark.parametrize("name", ["default", "work", "a", "p-1_2", "x" * 32])
def test_valid_profile_names(name: str) -> None:
    assert validate_browser_profile_name(name) == name


@pytest.mark.parametrize("name", ["", "Bad Name", "../etc", "-lead", "x" * 33, "work\n"])
def test_invalid_profile_names(name: str) -> None:
    with pytest.raises(ValueError, match="invalid profile name"):
        validate_browser_profile_name(name)


@pytest.mark.parametrize(
    ("tab_id", "valid"),
    [
        ("btab_7f3a9c2e", True),
        ("A-b_9", True),
        ("x" * 128, True),
        ("", False),
        ("x" * 129, False),
        ("../x", False),
        ("a.b", False),
        ("a/b", False),
    ],
)
def test_tab_id_validation(tab_id: str, valid: bool) -> None:
    assert is_valid_browser_tab_id(tab_id) is valid


@pytest.mark.parametrize("rest_fixture", ["create.json", "list.json"])
def test_tab_resource_matches_rest_fixture(rest_fixture: str) -> None:
    """Host tab records project onto the REST fixture's resources (null == absent)."""
    rest = json.loads((_FIXTURES / "rest" / rest_fixture).read_text(encoding="utf-8"))
    expected = rest["body"]["data"] if rest_fixture == "list.json" else [rest["body"]]
    for resource in expected:
        tab = {
            **{k: v for k, v in resource["metadata"].items() if v is not None},
            "id": resource["id"],
            "session_id": resource["session_id"],
            "target_id": "T1",
        }
        projected = browser_tab_resource(resource["session_id"], tab)
        resource_without_nulls = {
            **resource,
            "metadata": {k: v for k, v in resource["metadata"].items() if v is not None},
        }
        assert projected == resource_without_nulls


def test_tab_resource_requires_an_id() -> None:
    with pytest.raises(ValueError, match="without an id"):
        browser_tab_resource("conv_a", {"url": "about:blank"})
