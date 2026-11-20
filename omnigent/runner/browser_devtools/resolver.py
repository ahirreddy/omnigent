"""Which browser a session's agent connection uses.

The owner's Mac app browser comes first when it runs on this machine: the user is
there and the agent gets their logins. Otherwise this runner's browser host
serves the session, so browsing works with the laptop closed.
"""

from __future__ import annotations

import httpx

from omnigent.entities.remote_browser import DEFAULT_BROWSER_PROFILE
from omnigent.runner.browser_devtools.app_backend import app_backend
from omnigent.runner.browser_devtools.host_backend import PublishEvent, host_backend
from omnigent.runner.browser_devtools.server import BrowserBackend, BrowserUnavailableError
from omnigent.runner.browser_host import BrowserHostManager


class RunnerBrowserResolver:
    """Pick the local (Mac app) or remote (browser host) browser for a session.

    :param manager: The runner's browser host manager.
    :param publish_event: The runner's session event emitter.
    :param server_client: The runner's authenticated server client, for the
        app relay; ``None`` offers only the browser host.
    """

    def __init__(
        self,
        manager: BrowserHostManager,
        publish_event: PublishEvent,
        server_client: httpx.AsyncClient | None,
    ) -> None:
        self._manager = manager
        self._publish_event = publish_event
        self._server_client = server_client

    async def resolve(self, session_id: str) -> BrowserBackend:
        """Return the first usable backend; explain both refusals when neither is."""
        local_reason = "the runner has no server connection"
        if self._server_client is not None:
            try:
                return await app_backend(self._server_client, session_id)
            except BrowserUnavailableError as exc:
                local_reason = str(exc)
        try:
            return await host_backend(
                self._manager, session_id, self._publish_event, profile=DEFAULT_BROWSER_PROFILE
            )
        except BrowserUnavailableError as exc:
            raise BrowserUnavailableError(
                f"No browser is available to this session. This Mac's browser: {local_reason} "
                f"The agent machine's browser: {exc}"
            ) from exc
