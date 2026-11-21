"""Which browser a session's agent connection uses.

The session label ``omnigent.browser_target`` picks one: ``local`` (the owner's
Mac app browser, with their logins), ``remote`` (this runner's browser host,
which works with the laptop closed) or ``auto`` (absent). ``auto`` prefers the
Mac browser when it runs on this machine, since the user is there, except for
unattended runs (scheduled automations), which prefer the remote browser.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Mapping
from typing import Final, Literal

import httpx

from omnigent.entities.remote_browser import DEFAULT_BROWSER_PROFILE
from omnigent.runner.browser_devtools.app_backend import app_backend
from omnigent.runner.browser_devtools.host_backend import PublishEvent, host_backend
from omnigent.runner.browser_devtools.server import BrowserBackend, BrowserUnavailableError
from omnigent.runner.browser_host import BrowserHostManager
from omnigent.stores.conversation_store import (
    SCHEDULED_TASK_ORIGIN_LABEL_KEY,
    SCHEDULED_TASK_RUN_LABEL_KEY,
)

BROWSER_TARGET_LABEL: Final[str] = "omnigent.browser_target"
BackendKind = Literal["local", "remote"]
LabelReader = Callable[[str], Awaitable[Mapping[str, str]]]

_DESCRIPTIONS: Final[dict[BackendKind, str]] = {
    "local": "This Mac's browser",
    "remote": "The agent machine's browser",
}


def backend_order(labels: Mapping[str, str]) -> tuple[BackendKind, ...]:
    """The backends to try for a session with *labels*, in order.

    :param labels: The session's labels.
    :returns: One backend for an explicit choice, else both in ``auto`` order.
    """
    target = labels.get(BROWSER_TARGET_LABEL, "auto")
    if target == "local":
        return ("local",)
    if target == "remote":
        return ("remote",)
    if SCHEDULED_TASK_ORIGIN_LABEL_KEY in labels or SCHEDULED_TASK_RUN_LABEL_KEY in labels:
        return ("remote", "local")
    return ("local", "remote")


class RunnerBrowserResolver:
    """Pick the local (Mac app) or remote (browser host) browser for a session.

    :param manager: The runner's browser host manager.
    :param publish_event: The runner's session event emitter.
    :param server_client: The runner's authenticated server client, for the app
        relay and the session's labels; ``None`` offers only the browser host.
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

    async def labels(self, session_id: str) -> Mapping[str, str]:
        """The session's labels; empty without a server connection or when unreadable."""
        if self._server_client is None:
            return {}
        from omnigent.runner.native.orchestration import _session_labels_for_runner_spawn

        return await _session_labels_for_runner_spawn(
            server_client=self._server_client, session_id=session_id
        )

    async def still_selected(self, session_id: str, kind: str) -> bool:
        """Whether *kind* is still allowed by the session's ``omnigent.browser_target``."""
        order = backend_order(await self.labels(session_id))
        return len(order) > 1 or order[0] == kind

    async def resolve(self, session_id: str) -> BrowserBackend:
        """Return the first usable backend in the session's order; explain every refusal."""
        refusals: list[str] = []
        for kind in backend_order(await self.labels(session_id)):
            try:
                return await self._backend(kind, session_id)
            except BrowserUnavailableError as exc:
                refusals.append(f"{_DESCRIPTIONS[kind]}: {exc}")
        raise BrowserUnavailableError(
            "No browser is available to this session. " + " ".join(refusals)
        )

    async def _backend(self, kind: BackendKind, session_id: str) -> BrowserBackend:
        if kind == "local":
            if self._server_client is None:
                raise BrowserUnavailableError("the runner has no server connection.")
            return await app_backend(self._server_client, session_id)
        return await host_backend(
            self._manager, session_id, self._publish_event, profile=DEFAULT_BROWSER_PROFILE
        )
