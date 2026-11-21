"""The remote browser backend: a per-profile ``omnigent-browser-host`` on this machine.

The host already opens a loopback CDP port per profile (``host.json`` ``cdp_port``)
and tags every tab with its session. :class:`HostTabDirectory` reads the
session's tabs over ``host.sock`` and opens agent tabs with ``tabs.create``, so a
CDP ``Target.createTarget`` never makes Chromium's non-painting default browser.
"""

from __future__ import annotations

import logging
from collections.abc import Callable, Mapping
from typing import Final, cast

from omnigent.entities.remote_browser import DEFAULT_BROWSER_PROFILE, browser_tab_resource
from omnigent.runner.browser_devtools.directory import (
    AgentTabState,
    ScopedTab,
    TabDirectoryError,
    TabOwner,
)
from omnigent.runner.browser_devtools.server import (
    BrowserBackend,
    BrowserUnavailableError,
    browser_websocket_url,
)
from omnigent.runner.browser_host import (
    BrowserHostError,
    BrowserHostManager,
    HostProtocolError,
    HostState,
    host_request,
)

_logger = logging.getLogger(__name__)

# Host tab listing is a local socket round trip, cheap enough to poll each second.
_HOST_REFRESH_INTERVAL_S: Final[float] = 1.0

PublishEvent = Callable[[str, Mapping[str, object]], None]


def _scoped_tab(record: Mapping[str, object]) -> ScopedTab:
    owner = record.get("owner")
    return ScopedTab(
        tab_id=str(record.get("id") or ""),
        target_id=str(record.get("target_id") or ""),
        url=str(record.get("url") or ""),
        title=str(record.get("title") or ""),
        owner=cast(TabOwner, owner) if owner in ("agent", "user") else "agent",
    )


class HostTabDirectory:
    """One session's tabs in one profile's browser host.

    :param manager: The runner's browser host manager.
    :param state: The running host of the profile.
    :param session_id: The session, e.g. ``"conv_abc123"``.
    :param publish_event: The runner's session event emitter, used to announce
        agent-opened tabs so clients show them.
    """

    def __init__(
        self,
        manager: BrowserHostManager,
        state: HostState,
        session_id: str,
        publish_event: PublishEvent,
    ) -> None:
        self._manager = manager
        self._state = state
        self._session_id = session_id
        self._publish_event = publish_event
        self._agent_state_supported = True

    @property
    def refresh_interval_s(self) -> float:
        """Poll interval while an agent is connected."""
        return _HOST_REFRESH_INTERVAL_S

    async def _records(self) -> list[dict[str, object]]:
        try:
            result = await host_request(
                self._state.socket, "tabs.list", {"session_id": self._session_id}
            )
        except (BrowserHostError, HostProtocolError, OSError) as exc:
            raise TabDirectoryError(f"The browser host did not list tabs: {exc}") from exc
        tabs = result.get("tabs")
        if not isinstance(tabs, list):
            raise TabDirectoryError("The browser host answered tabs.list without a tab list.")
        return [tab for tab in tabs if isinstance(tab, dict)]

    async def list_tabs(self) -> list[ScopedTab]:
        """List the session's tabs in this profile."""
        return [_scoped_tab(record) for record in await self._records()]

    async def create_tab(self, url: str) -> ScopedTab:
        """Open an agent tab for the session and announce it to clients."""
        try:
            record = await self._manager.create_tab(
                self._session_id,
                profile=self._state.profile,
                url=url,
                created_by="agent",
            )
        except (BrowserHostError, HostProtocolError, OSError) as exc:
            raise TabDirectoryError(f"The browser host could not open a tab: {exc}") from exc
        self._publish_event(
            self._session_id,
            {
                "type": "session.resource.created",
                "resource": browser_tab_resource(self._session_id, record),
            },
        )
        return _scoped_tab(record)

    async def _tab_id(self, target_id: str) -> str:
        for record in await self._records():
            if record.get("target_id") == target_id:
                return str(record.get("id"))
        raise TabDirectoryError("No target with given id found")

    async def close_tab(self, target_id: str) -> None:
        """Close the session's tab for *target_id* and announce its deletion."""
        tab_id = await self._tab_id(target_id)
        try:
            closed = await self._manager.close_tab(self._session_id, tab_id)
        except (BrowserHostError, HostProtocolError, OSError) as exc:
            raise TabDirectoryError(f"The browser host could not close the tab: {exc}") from exc
        if not closed:
            raise TabDirectoryError("No target with given id found")
        self._publish_event(
            self._session_id,
            {
                "type": "session.resource.deleted",
                "resource_id": tab_id,
                "resource_type": "browser",
                "session_id": self._session_id,
            },
        )

    async def report_agent_state(self, target_id: str, state: AgentTabState) -> None:
        """Badge the host tab; hosts older than ``tabs.agent_state`` just skip the badge."""
        if not self._agent_state_supported:
            return
        tab_ids = [
            str(record.get("id"))
            for record in await self._records()
            if record.get("target_id") == target_id
        ]
        if not tab_ids:
            return  # The tab closed; there is nothing left to badge.
        try:
            await host_request(
                self._state.socket, "tabs.agent_state", {"tab_id": tab_ids[0], "state": state}
            )
        except BrowserHostError as exc:
            if exc.code == "invalid_input" and "unknown op" in exc.message:
                _logger.info(
                    "browser host %s has no tabs.agent_state; tabs show no agent badge",
                    self._state.version,
                    extra={"session_id": self._session_id},
                )
                self._agent_state_supported = False
                return
            raise TabDirectoryError(f"The browser host refused the agent state: {exc}") from exc
        except (HostProtocolError, OSError) as exc:
            raise TabDirectoryError(f"The browser host refused the agent state: {exc}") from exc


async def host_backend(
    manager: BrowserHostManager,
    session_id: str,
    publish_event: PublishEvent,
    *,
    profile: str = DEFAULT_BROWSER_PROFILE,
) -> BrowserBackend:
    """Start (or reuse) *profile*'s host and return it as *session_id*'s backend.

    :raises BrowserUnavailableError: When hosts cannot run here or the host has no CDP port.
    """
    availability = await manager.availability()
    if availability.status != "available":
        raise BrowserUnavailableError(f"This runner has no agent browser: {availability.message}")
    try:
        state = await manager.ensure_host(profile)
    except BrowserHostError as exc:
        raise BrowserUnavailableError(f"The browser host did not start: {exc}") from exc
    if state.cdp_port is None:
        raise BrowserUnavailableError("The browser host did not open a DevTools port.")
    return BrowserBackend(
        upstream_url=await browser_websocket_url(state.cdp_port),
        directory=HostTabDirectory(manager, state, session_id, publish_event),
        kind="remote",
    )
