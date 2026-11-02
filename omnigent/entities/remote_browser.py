"""Remote agent browser constants and projections shared by the server and runner.

The wire protocol itself (section 5 of ``apps/apple/docs/remote-browser-design.md``)
is terminated by the browser host and the Rust client core; the server and runner
only splice it. This module holds the few rules both relay hops enforce: attach
modes, close codes, the view-mode input filter and the tab resource projection.
"""

from __future__ import annotations

import json
import re
from collections.abc import Mapping
from typing import Final, Literal

BrowserAttachMode = Literal["view", "control"]
BROWSER_ATTACH_MODES: Final[frozenset[str]] = frozenset({"view", "control"})

REMOTE_BROWSER_PROTOCOL_VERSION: Final[int] = 1

DEFAULT_BROWSER_PROFILE: Final[str] = "default"
# Profile names become directory and socket names on the agent machine.
_BROWSER_PROFILE_NAME_RE: Final[re.Pattern[str]] = re.compile(r"[a-z0-9][a-z0-9_-]{0,31}")
# Tab ids are opaque to clients but always path-safe.
_BROWSER_TAB_ID_RE: Final[re.Pattern[str]] = re.compile(r"[A-Za-z0-9_-]{1,128}")

# Close codes from section 5.8; 4400 and 4500 are shared with terminal attach.
WS_CLOSE_TAB_NOT_FOUND: Final[int] = 4404
WS_CLOSE_CONTROL_NOT_PERMITTED: Final[int] = 4403
WS_CLOSE_PROTOCOL_UNSUPPORTED: Final[int] = 4426

# Client message types a view-only attach may send; everything else is input.
VIEW_MODE_CLIENT_MESSAGE_TYPES: Final[frozenset[str]] = frozenset(
    {"hello", "ack", "keyframe_request", "visibility", "still_request", "ping"}
)
# ``settings`` fields a view-only attach may change (per-connection only).
_VIEW_MODE_SETTINGS_FIELDS: Final[frozenset[str]] = frozenset({"type", "stats"})


def validate_browser_profile_name(name: str) -> str:
    """Return *name* when it is a valid browser profile name.

    :param name: Requested profile, e.g. ``"default"`` or ``"work"``.
    :returns: The same name.
    :raises ValueError: When the name is empty, longer than 32, or contains
        characters other than lowercase letters, digits, ``_`` and ``-``.
    """
    if not _BROWSER_PROFILE_NAME_RE.fullmatch(name):
        raise ValueError(
            f"invalid profile name {name!r}: use 1-32 lowercase letters, digits, '_' or '-'"
        )
    return name


def is_valid_browser_tab_id(tab_id: str) -> bool:
    """Return whether *tab_id* matches ``[A-Za-z0-9_-]{1,128}``."""
    return _BROWSER_TAB_ID_RE.fullmatch(tab_id) is not None


def view_mode_allows_client_frame(data: str | bytes) -> bool:
    """Return whether a view-only attach may forward this client frame.

    Clients never send binary frames, and a view attach may only send the
    non-input messages in :data:`VIEW_MODE_CLIENT_MESSAGE_TYPES` plus a
    ``settings`` message that only toggles ``stats``. Unparseable text is
    dropped rather than forwarded.

    :param data: One client WebSocket payload.
    :returns: ``True`` when the frame should reach the host.
    """
    if not isinstance(data, str):
        return False
    try:
        message = json.loads(data)
    except ValueError:
        return False
    if not isinstance(message, dict):
        return False
    message_type = message.get("type")
    if message_type == "settings":
        return set(message) <= _VIEW_MODE_SETTINGS_FIELDS
    return message_type in VIEW_MODE_CLIENT_MESSAGE_TYPES


# Host tab-record fields surfaced as resource metadata.
_TAB_METADATA_FIELDS: Final[tuple[str, ...]] = (
    "url",
    "title",
    "loading",
    "owner",
    "needs_attention",
    "profile",
    "created_by",
    "can_go_back",
    "can_go_forward",
    "thumbnail_url",
)


def browser_tab_resource(session_id: str, tab: Mapping[str, object]) -> dict[str, object]:
    """Project a host tab record onto the public ``session.resource`` shape.

    :param session_id: Owning session id, e.g. ``"conv_abc123"``.
    :param tab: Tab record from the host's ``tabs.list`` / ``tabs.create``,
        e.g. ``{"id": "tab_1", "url": "https://example.com", ...}``.
    :returns: ``{"id", "object", "type": "browser", "session_id", "name", "metadata"}``.
    :raises ValueError: When the record has no string ``id``.
    """
    tab_id = tab.get("id")
    if not isinstance(tab_id, str) or not tab_id:
        raise ValueError(f"browser host returned a tab without an id: {dict(tab)!r}")
    metadata = {key: tab[key] for key in _TAB_METADATA_FIELDS if key in tab}
    title = tab.get("title")
    return {
        "id": tab_id,
        "object": "session.resource",
        "type": "browser",
        "session_id": session_id,
        "name": title if isinstance(title, str) else "",
        "metadata": metadata,
    }
