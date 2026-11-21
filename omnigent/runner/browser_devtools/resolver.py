"""Which browser a session's agent connection uses.

The session label ``omnigent.browser_target`` picks one: ``local`` (the owner's
Mac app browser, with their logins), ``remote`` (this runner's browser host,
which works with the laptop closed) or ``auto`` (absent). ``auto`` prefers the
Mac browser when it runs on this machine, since the user is there, except for
unattended runs (scheduled automations), which prefer the remote browser. When
both browsers would do for an attended run, the first connection asks the owner
once and keeps the answer in the label. A shared session never asks: the server
refuses it the Mac browser.
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable, Mapping
from typing import Any, Final, Literal

import httpx

from omnigent.browser_devtools_availability import BROWSER_TARGET_LABEL
from omnigent.entities.remote_browser import DEFAULT_BROWSER_PROFILE
from omnigent.runner import pending_approvals
from omnigent.runner.browser_devtools.app_backend import app_backend
from omnigent.runner.browser_devtools.choice import (
    BrowserChoiceError,
    ask_owner,
    write_browser_target,
)
from omnigent.runner.browser_devtools.host_backend import PublishEvent, host_backend
from omnigent.runner.browser_devtools.server import BrowserBackend, BrowserUnavailableError
from omnigent.runner.browser_host import BrowserHostManager
from omnigent.stores.conversation_store import (
    SCHEDULED_TASK_ORIGIN_LABEL_KEY,
    SCHEDULED_TASK_RUN_LABEL_KEY,
)

BackendKind = Literal["local", "remote"]
LabelReader = Callable[[str], Awaitable[Mapping[str, str]]]

_DESCRIPTIONS: Final[dict[BackendKind, str]] = {
    "local": "This Mac's browser",
    "remote": "The agent machine's browser",
}
_logger = logging.getLogger(__name__)

ASK_MESSAGE: Final[str] = "Use this Mac's browser (your logins) or the agent's machine?"
# Long enough to notice the card, short of chrome-devtools-mcp's 180 s tool timeout.
ASK_TIMEOUT_S: Final[float] = 120.0
ASK_SCHEMA: Final[dict[str, Any]] = {
    "type": "object",
    "properties": {
        "browser": {
            "type": "string",
            "title": "Browser",
            "oneOf": [
                {"const": "local", "title": "This Mac (your logins)"},
                {"const": "remote", "title": "Agent's machine (works while your Mac sleeps)"},
            ],
            "default": "local",
        }
    },
    "required": ["browser"],
}


def _unattended(labels: Mapping[str, str]) -> bool:
    """A scheduled automation's run, which nobody watches."""
    return SCHEDULED_TASK_ORIGIN_LABEL_KEY in labels or SCHEDULED_TASK_RUN_LABEL_KEY in labels


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
    if _unattended(labels):
        return ("remote", "local")
    return ("local", "remote")


def asks_owner(labels: Mapping[str, str]) -> bool:
    """Whether the session leaves the browser to ``auto`` in a run someone watches."""
    return labels.get(BROWSER_TARGET_LABEL) not in ("local", "remote") and not _unattended(labels)


def chosen_browser(verdict: pending_approvals.Verdict) -> BackendKind | None:
    """The owner's answer to :data:`ASK_MESSAGE`; ``None`` when declined or unanswered.

    A bare accept, from a card that showed no choices, takes the default (this Mac).
    """
    if not verdict.approved:
        return None
    answer = (verdict.content or {}).get("browser", "local")
    if answer == "local":
        return "local"
    if answer == "remote":
        return "remote"
    return None


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
        # Sessions already asked which browser to use, answered or not.
        self._asked: set[str] = set()

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
        """Return the first usable backend in the session's order; explain every refusal.

        Under ``auto`` in a watched run, a usable Mac browser with a usable remote one
        asks the owner once (:meth:`_ask_once`).
        """
        labels = await self.labels(session_id)
        refusals: list[str] = []
        for kind in backend_order(labels):
            try:
                backend = await self._backend(kind, session_id)
            except BrowserUnavailableError as exc:
                refusals.append(f"{_DESCRIPTIONS[kind]}: {exc}")
                continue
            if kind == "local" and asks_owner(labels):
                return await self._ask_once(session_id, backend)
            return backend
        raise BrowserUnavailableError(
            "No browser is available to this session. " + " ".join(refusals)
        )

    async def _ask_once(self, session_id: str, local: BrowserBackend) -> BrowserBackend:
        """Ask which browser to use when the remote one would do too; keep the answer.

        A declined, unanswered or failed question keeps the Mac browser for now and is
        not asked again while this runner runs.
        """
        if self._server_client is None or session_id in self._asked:
            return local
        if (await self._manager.availability()).status != "available":
            return local
        self._asked.add(session_id)
        try:
            verdict = await ask_owner(
                self._server_client,
                session_id,
                self._publish_event,
                message=ASK_MESSAGE,
                timeout_s=ASK_TIMEOUT_S,
                requested_schema=ASK_SCHEMA,
            )
        except BrowserChoiceError as exc:
            _logger.warning(
                "could not ask which browser to use: %s", exc, extra={"session_id": session_id}
            )
            return local
        choice = chosen_browser(verdict)
        if choice is None:
            return local
        try:
            await write_browser_target(self._server_client, session_id, choice)
        except BrowserChoiceError as exc:
            _logger.warning(
                "could not save the browser choice: %s", exc, extra={"session_id": session_id}
            )
        if choice == "local":
            return local
        if local.upstream is not None:
            await local.upstream.close()
        try:
            return await self._backend("remote", session_id)
        except BrowserUnavailableError as exc:
            raise BrowserUnavailableError(f"{_DESCRIPTIONS['remote']}: {exc}") from exc

    async def _backend(self, kind: BackendKind, session_id: str) -> BrowserBackend:
        if kind == "local":
            if self._server_client is None:
                raise BrowserUnavailableError("the runner has no server connection.")
            return await app_backend(self._server_client, session_id)
        return await host_backend(
            self._manager, session_id, self._publish_event, profile=DEFAULT_BROWSER_PROFILE
        )
