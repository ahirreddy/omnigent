"""Unit tests for checking Claude's permission suggestions before they are offered or applied."""

from typing import Any

import pytest

from omnigent.server.claude_permission_updates import claude_permission_suggestions

_EVERY_KIND = [
    {
        "type": "addRules",
        "rules": [{"toolName": "Bash", "ruleContent": "npm test:*"}, {"toolName": "Read"}],
        "behavior": "allow",
        "destination": "localSettings",
    },
    {
        "type": "replaceRules",
        "rules": [{"toolName": "Edit", "ruleContent": ""}],
        "behavior": "ask",
        "destination": "projectSettings",
    },
    {
        "type": "removeRules",
        "rules": [{"toolName": "Write"}],
        "behavior": "deny",
        "destination": "userSettings",
    },
    {"type": "setMode", "mode": "acceptEdits", "destination": "session"},
    {"type": "addDirectories", "directories": ["/workspace/shared"], "destination": "cliArg"},
    {"type": "removeDirectories", "directories": ["/workspace/old"], "destination": "session"},
]


def test_every_update_kind_is_kept_as_sent() -> None:
    assert claude_permission_suggestions(_EVERY_KIND) == _EVERY_KIND


def test_keys_an_update_does_not_take_are_dropped() -> None:
    sent = [
        {
            "type": "setMode",
            "mode": "auto",
            "destination": "session",
            "rules": [{"toolName": "Bash"}],
            "directories": ["/"],
        }
    ]
    assert claude_permission_suggestions(sent) == [
        {"type": "setMode", "mode": "auto", "destination": "session"}
    ]


@pytest.mark.parametrize(
    "bad",
    [
        "setMode",
        {"type": "setMode", "mode": "turbo", "destination": "session"},
        {"type": "setMode", "mode": "auto"},
        {"type": "setMode", "mode": "auto", "destination": "everywhere"},
        {"type": "addRules", "rules": [], "behavior": "allow", "destination": "session"},
        {
            "type": "addRules",
            "rules": [{"toolName": ""}],
            "behavior": "allow",
            "destination": "session",
        },
        {
            "type": "addRules",
            "rules": [{"toolName": "Bash", "ruleContent": None}],
            "behavior": "allow",
            "destination": "session",
        },
        {"type": "addRules", "rules": [{"toolName": "Bash"}], "destination": "session"},
        {"type": "addDirectories", "directories": [], "destination": "session"},
        {"type": "addDirectories", "directories": [" "], "destination": "session"},
        {"type": "addDirectories", "directories": ["/a\0b"], "destination": "session"},
        {"type": "grantEverything", "destination": "session"},
    ],
)
def test_one_malformed_update_withholds_the_list(bad: Any) -> None:
    assert claude_permission_suggestions([_EVERY_KIND[3], bad]) is None


@pytest.mark.parametrize("raw", [None, [], {"type": "setMode"}, "addRules"])
def test_no_list_offers_nothing(raw: Any) -> None:
    assert claude_permission_suggestions(raw) is None
