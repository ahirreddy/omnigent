"""Claude's permission updates: the suggestions its prompts offer, and plan approval modes.

A Claude permission request carries ``permission_suggestions``: the rule, mode
and directory updates Claude's own prompt applies when the user picks "Yes, and
don't ask again". The server publishes a checked copy, and applies that same
copy when the user accepts with ``apply_suggestions``, never a client-supplied
list. Kept dependency-free (stdlib/typing only) so harness code can import it.
"""

from __future__ import annotations

from typing import Any

#: Permission modes Claude accepts in a ``setMode`` update.
CLAUDE_PERMISSION_MODES = frozenset(
    {"default", "acceptEdits", "plan", "bypassPermissions", "dontAsk", "auto"}
)
#: Modes an approved plan may switch to, besides the plain approval's ``default``:
#: Claude's "Yes, and use auto mode" and "Yes, auto-accept edits".
CLAUDE_PLAN_APPROVAL_MODES: tuple[str, ...] = ("auto", "acceptEdits")

_DESTINATIONS = frozenset(
    {"session", "localSettings", "projectSettings", "userSettings", "cliArg"}
)
_RULE_BEHAVIORS = frozenset({"allow", "deny", "ask"})
_RULE_UPDATES = frozenset({"addRules", "replaceRules", "removeRules"})
_DIRECTORY_UPDATES = frozenset({"addDirectories", "removeDirectories"})


def _rules(raw: Any) -> list[dict[str, str]] | None:
    """A non-empty rule list, each ``{toolName, ruleContent?}``; ``None`` otherwise."""
    if not isinstance(raw, list) or not raw:
        return None
    rules: list[dict[str, str]] = []
    for entry in raw:
        if not isinstance(entry, dict):
            return None
        tool_name = entry.get("toolName")
        if not isinstance(tool_name, str) or not tool_name:
            return None
        rule: dict[str, str] = {"toolName": tool_name}
        # Claude refuses a ``null`` content (and every update sent with it).
        if "ruleContent" in entry:
            content = entry["ruleContent"]
            if not isinstance(content, str):
                return None
            rule["ruleContent"] = content
        rules.append(rule)
    return rules


def _directories(raw: Any) -> list[str] | None:
    """A non-empty list of non-blank paths without NUL; ``None`` otherwise."""
    if not isinstance(raw, list) or not raw:
        return None
    if any(not isinstance(path, str) or not path.strip() or "\0" in path for path in raw):
        return None
    return list(raw)


def _permission_update(raw: Any) -> dict[str, Any] | None:
    """One update with only the keys its type takes; ``None`` when malformed."""
    if not isinstance(raw, dict):
        return None
    kind = raw.get("type")
    destination = raw.get("destination")
    if destination not in _DESTINATIONS:
        return None
    update: dict[str, Any] = {"type": kind}
    if kind in _RULE_UPDATES:
        rules = _rules(raw.get("rules"))
        behavior = raw.get("behavior")
        if rules is None or behavior not in _RULE_BEHAVIORS:
            return None
        update["rules"] = rules
        update["behavior"] = behavior
    elif kind == "setMode":
        mode = raw.get("mode")
        if mode not in CLAUDE_PERMISSION_MODES:
            return None
        update["mode"] = mode
    elif kind in _DIRECTORY_UPDATES:
        directories = _directories(raw.get("directories"))
        if directories is None:
            return None
        update["directories"] = directories
    else:
        return None
    update["destination"] = destination
    return update


def claude_permission_suggestions(raw: Any) -> list[dict[str, Any]] | None:
    """
    Check Claude's ``permission_suggestions`` and copy them for publishing and applying.

    :param raw: The hook payload's ``permission_suggestions``, e.g.
        ``[{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent":
        "npm test:*"}], "behavior": "allow", "destination": "localSettings"}]``.
    :returns: Every update, each with only the keys its type takes, or ``None``
        when there are none or any is malformed: a partial list would apply
        less than the card describes.
    """
    if not isinstance(raw, list) or not raw:
        return None
    updates = [_permission_update(entry) for entry in raw]
    if any(update is None for update in updates):
        return None
    return [update for update in updates if update is not None]
