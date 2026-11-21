"""The session's view of a browser: its tabs, who holds them, and how to add one.

Each browser backend (the Mac app's browser, a remote browser host) implements
:class:`TabDirectory`. The proxy asks it which CDP targets belong to the
session, turns new-page requests into real tabs, and reports what the agent is
doing so the browser can badge the tab.
"""

from __future__ import annotations

import dataclasses
from typing import Literal, Protocol

TabOwner = Literal["agent", "user"]
AgentTabState = Literal["active", "idle", "released"]


class TabDirectoryError(Exception):
    """A backend could not answer a directory request.

    :param message: Text safe to show the agent, e.g. ``"The browser host is not running"``.
    """


@dataclasses.dataclass(frozen=True)
class ScopedTab:
    """One of the session's tabs as the backend reports it.

    :param tab_id: The backend's tab id, e.g. ``"tab_3"``.
    :param target_id: The tab's CDP target id; empty while the browser has not reported it.
    :param url: Current URL, e.g. ``"https://example.com/"``.
    :param title: Current title.
    :param owner: ``"user"`` while the user holds the tab, else ``"agent"``.
    """

    tab_id: str
    target_id: str
    url: str = ""
    title: str = ""
    owner: TabOwner = "agent"


class TabDirectory(Protocol):
    """Backend operations the proxy needs for one session."""

    @property
    def refresh_interval_s(self) -> float:
        """How often the proxy re-lists tabs while an agent is connected."""
        ...

    async def list_tabs(self) -> list[ScopedTab]:
        """List the session's tabs.

        :raises TabDirectoryError: When the backend cannot answer.
        """
        ...

    async def create_tab(self, url: str) -> ScopedTab:
        """Open a background tab for the session at *url*.

        :raises TabDirectoryError: When the backend refuses or fails.
        """
        ...

    async def close_tab(self, target_id: str) -> None:
        """Close the session's tab whose CDP target is *target_id*.

        :raises TabDirectoryError: When the tab is unknown or the backend fails.
        """
        ...

    async def report_agent_state(self, target_id: str, state: AgentTabState) -> None:
        """Tell the backend what the agent is doing on a tab, for its badge.

        :raises TabDirectoryError: When the backend fails.
        """
        ...
