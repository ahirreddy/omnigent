"""Locate, spawn and talk to the per-profile ``omnigent-browser-host`` processes.

Each browser profile runs in its own host process with its own CEF cache,
loopback CDP port and Unix socket (``host.sock``). The runner starts a host on
demand, reuses a live one (hosts outlive runner restarts), and respawns one
whose process died. All runner-to-host traffic uses the length-prefixed
framing below:

- ``u32`` little-endian payload length (the 5-byte prefix excluded),
- ``u8`` kind: 1 text (UTF-8 JSON), 2 binary (RB media header + payload),
  3 close (``u16`` little-endian code + UTF-8 reason),
- the payload.

A connection starts with one text preamble: ``{"type": "control"}`` opens a
request/response channel, ``{"type": "attach", ...}`` turns the connection into
the client protocol splice for one tab.
"""

from __future__ import annotations

import asyncio
import contextlib
import dataclasses
import enum
import hashlib
import json
import logging
import os
import secrets
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
from collections.abc import Mapping
from pathlib import Path
from typing import Final, Literal

from omnigent.entities.remote_browser import (
    DEFAULT_BROWSER_PROFILE,
    REMOTE_BROWSER_PROTOCOL_VERSION,
    BrowserAttachMode,
    validate_browser_profile_name,
)

_logger = logging.getLogger(__name__)

HOST_BINARY_NAME: Final[str] = "omnigent-browser-host"
# Hello capability advertised when this runner can serve remote browser tabs.
CAP_REMOTE_BROWSER: Final[str] = "remote_browser"

MAX_HOST_FRAME_BYTES: Final[int] = 16 * 1024 * 1024
_FRAME_PREFIX_BYTES: Final[int] = 5
# macOS caps sun_path at 104 bytes and Linux at 108; stay under both.
_MAX_SOCKET_PATH_BYTES: Final[int] = 100
_HOST_LOG_TAIL_BYTES: Final[int] = 4096
_HOST_START_POLL_S: Final[float] = 0.05
_DEFAULT_HOST_START_TIMEOUT_S: Final[float] = 30.0
_DEFAULT_HOST_REQUEST_TIMEOUT_S: Final[float] = 10.0
# tabs.create answers once CEF has created the browser and its DevTools target.
_TAB_CREATE_TIMEOUT_S: Final[float] = 30.0
_ENCODER_PROBE_TIMEOUT_S: Final[float] = 5.0

ENV_ENABLED: Final[str] = "OMNIGENT_REMOTE_BROWSER"
ENV_HOST_BIN: Final[str] = "OMNIGENT_BROWSER_HOST_BIN"
ENV_RUNTIME_DIR: Final[str] = "OMNIGENT_BROWSER_RUNTIME_DIR"
ENV_ENCODER: Final[str] = "OMNIGENT_BROWSER_ENCODER"
ENV_HOST_ARGS: Final[str] = "OMNIGENT_BROWSER_HOST_ARGS"
ENV_START_TIMEOUT: Final[str] = "OMNIGENT_BROWSER_HOST_START_TIMEOUT_S"

BrowserHostErrorCode = Literal["not_found", "invalid_input", "internal", "unavailable"]
BrowserHostStatus = Literal["available", "disabled", "not_installed", "encoder_missing"]


class HostFrameKind(enum.IntEnum):
    """Kind byte of one ``host.sock`` frame."""

    TEXT = 1
    BINARY = 2
    CLOSE = 3


class HostProtocolError(Exception):
    """The host sent bytes that violate the socket framing."""


class HostFrameTooLargeError(HostProtocolError):
    """A frame exceeded :data:`MAX_HOST_FRAME_BYTES`; maps to WS close 1009."""


class BrowserHostError(Exception):
    """A host operation failed.

    :param code: ``not_found``, ``invalid_input``, ``internal`` or
        ``unavailable`` (host missing, starting, crashed or shutting down).
    :param message: Human-readable detail.
    """

    def __init__(self, code: BrowserHostErrorCode, message: str) -> None:
        super().__init__(message)
        self.code: BrowserHostErrorCode = code
        self.message = message


class BrowserCleanupError(Exception):
    """Closing a session's tabs failed on one or more profile hosts.

    :param session_id: The session being cleaned up.
    :param closed_tab_ids: Tabs that were closed on the hosts that worked.
    :param failures: Profile name to error message for each failed host.
    """

    def __init__(
        self, session_id: str, closed_tab_ids: list[str], failures: Mapping[str, str]
    ) -> None:
        detail = "; ".join(f"{profile}: {message}" for profile, message in failures.items())
        super().__init__(f"closing browser tabs for session {session_id} failed ({detail})")
        self.session_id = session_id
        self.closed_tab_ids = list(closed_tab_ids)
        self.failures = dict(failures)


@dataclasses.dataclass(frozen=True)
class HostFrame:
    """One decoded ``host.sock`` frame."""

    kind: HostFrameKind
    payload: bytes


def encode_host_frame(kind: HostFrameKind, payload: bytes) -> bytes:
    """Encode one frame for ``host.sock``.

    :param kind: Frame kind.
    :param payload: Frame payload.
    :returns: Prefix plus payload.
    :raises HostFrameTooLargeError: When *payload* exceeds the frame cap.
    """
    if len(payload) > MAX_HOST_FRAME_BYTES:
        raise HostFrameTooLargeError(f"frame of {len(payload)} bytes exceeds the host frame cap")
    return len(payload).to_bytes(4, "little") + bytes((kind,)) + payload


def encode_text_frame(message: Mapping[str, object] | str) -> bytes:
    """Encode a JSON control message (or pre-serialized JSON text) as a text frame."""
    text = message if isinstance(message, str) else json.dumps(message, separators=(",", ":"))
    return encode_host_frame(HostFrameKind.TEXT, text.encode("utf-8"))


def encode_close_payload(code: int, reason: str) -> bytes:
    """Encode a close frame payload: ``u16`` little-endian code plus UTF-8 reason."""
    return code.to_bytes(2, "little") + reason.encode("utf-8")


def decode_close_payload(payload: bytes) -> tuple[int, str]:
    """Decode a close frame payload into ``(code, reason)``.

    :raises HostProtocolError: When the payload is shorter than the code.
    """
    if len(payload) < 2:
        raise HostProtocolError("close frame is missing its code")
    return int.from_bytes(payload[:2], "little"), payload[2:].decode("utf-8", errors="replace")


async def read_host_frame(reader: asyncio.StreamReader) -> HostFrame | None:
    """Read one frame, or return ``None`` on a clean end of stream.

    :param reader: Stream connected to ``host.sock``.
    :returns: The frame, or ``None`` when the host closed between frames.
    :raises HostFrameTooLargeError: When the declared length exceeds the cap.
    :raises HostProtocolError: On a truncated frame or an unknown kind.
    """
    try:
        prefix = await reader.readexactly(_FRAME_PREFIX_BYTES)
    except asyncio.IncompleteReadError as exc:
        if not exc.partial:
            return None
        raise HostProtocolError("host closed mid frame prefix") from exc
    length = int.from_bytes(prefix[:4], "little")
    if length > MAX_HOST_FRAME_BYTES:
        raise HostFrameTooLargeError(f"host frame of {length} bytes exceeds the frame cap")
    try:
        kind = HostFrameKind(prefix[4])
    except ValueError as exc:
        raise HostProtocolError(f"unknown host frame kind {prefix[4]}") from exc
    try:
        payload = await reader.readexactly(length)
    except asyncio.IncompleteReadError as exc:
        raise HostProtocolError("host closed mid frame payload") from exc
    return HostFrame(kind=kind, payload=payload)


@dataclasses.dataclass(frozen=True)
class EncoderInfo:
    """The system H.264 encoder the host pipes frames through.

    :param path: Absolute executable path.
    :param kind: ``"x264"`` or ``"ffmpeg"``.
    """

    path: Path
    kind: Literal["x264", "ffmpeg"]


@dataclasses.dataclass(frozen=True)
class BrowserHostSettings:
    """Runner-side remote browser configuration.

    :param enabled: Feature switch (``OMNIGENT_REMOTE_BROWSER``).
    :param data_dir: Omnigent data dir; profiles live in ``<data_dir>/browser``.
    :param binary: Explicit host binary, or ``None`` to search.
    :param runtime_dir: Directory holding the host binary and CEF runtime.
    :param encoder: Explicit encoder executable, or ``None`` to search PATH.
    :param extra_args: Extra host arguments, e.g. ``("--no-sandbox",)``.
    :param start_timeout_s: Seconds to wait for a spawned host to answer.
    """

    enabled: bool
    data_dir: Path
    binary: Path | None = None
    runtime_dir: Path | None = None
    encoder: Path | None = None
    extra_args: tuple[str, ...] = ()
    start_timeout_s: float = _DEFAULT_HOST_START_TIMEOUT_S

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> BrowserHostSettings:
        """Read settings from the runner environment.

        :param env: Environment mapping; defaults to :data:`os.environ`.
        :raises ValueError: When the start timeout is not a positive number.
        """
        source = os.environ if env is None else env
        enabled = source.get(ENV_ENABLED, "").strip().lower() in {"1", "true", "yes", "on"}
        data_dir_raw = source.get("OMNIGENT_DATA_DIR", "").strip()
        data_dir = Path(data_dir_raw).expanduser() if data_dir_raw else Path.home() / ".omnigent"
        timeout_raw = source.get(ENV_START_TIMEOUT, "").strip()
        start_timeout = float(timeout_raw) if timeout_raw else _DEFAULT_HOST_START_TIMEOUT_S
        if start_timeout <= 0:
            raise ValueError(f"{ENV_START_TIMEOUT} must be positive, got {timeout_raw!r}")
        return cls(
            enabled=enabled,
            data_dir=data_dir,
            binary=_optional_path(source.get(ENV_HOST_BIN)),
            runtime_dir=_optional_path(source.get(ENV_RUNTIME_DIR)),
            encoder=_optional_path(source.get(ENV_ENCODER)),
            extra_args=tuple(shlex.split(source.get(ENV_HOST_ARGS, ""))),
            start_timeout_s=start_timeout,
        )

    @property
    def browser_dir(self) -> Path:
        """``<data_dir>/browser``: profiles, runtime and sockets."""
        return self.data_dir / "browser"


def _optional_path(raw: str | None) -> Path | None:
    value = (raw or "").strip()
    return Path(value).expanduser() if value else None


def _is_executable_file(path: Path) -> bool:
    return path.is_file() and os.access(path, os.X_OK)


def locate_host_binary(settings: BrowserHostSettings) -> Path | None:
    """Find the host binary: explicit path, runtime dir, installed runtime, then PATH.

    :returns: The executable, or ``None`` when no candidate exists.
    """
    if settings.binary is not None:
        return settings.binary if _is_executable_file(settings.binary) else None
    runtime_dirs: list[Path] = []
    if settings.runtime_dir is not None:
        runtime_dirs.append(settings.runtime_dir)
    runtime_root = settings.browser_dir / "runtime"
    runtime_dirs.append(runtime_root / "current")
    for runtime_dir in runtime_dirs:
        for candidate in (runtime_dir / HOST_BINARY_NAME, runtime_dir / "bin" / HOST_BINARY_NAME):
            if _is_executable_file(candidate):
                return candidate
    found = shutil.which(HOST_BINARY_NAME)
    return Path(found) if found else None


def _ffmpeg_has_libx264(ffmpeg: Path) -> bool:
    """Return whether *ffmpeg* lists the ``libx264`` encoder; ``False`` when it cannot run."""
    try:
        completed = subprocess.run(
            [str(ffmpeg), "-hide_banner", "-encoders"],
            capture_output=True,
            text=True,
            timeout=_ENCODER_PROBE_TIMEOUT_S,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        _logger.warning("cannot probe %s for libx264, not using it: %r", ffmpeg, exc)
        return False
    return completed.returncode == 0 and "libx264" in completed.stdout


def detect_encoder(settings: BrowserHostSettings) -> EncoderInfo | None:
    """Find the system H.264 encoder: ``x264``, else ``ffmpeg`` built with libx264.

    The host runs it as a separate process; the runner never links it.

    :returns: The encoder, or ``None`` when neither is usable.
    """
    candidates: list[Path] = []
    if settings.encoder is not None:
        candidates.append(settings.encoder)
    else:
        for name in ("x264", "ffmpeg"):
            found = shutil.which(name)
            if found:
                candidates.append(Path(found))
    for candidate in candidates:
        if not _is_executable_file(candidate):
            continue
        if "ffmpeg" in candidate.name:
            if _ffmpeg_has_libx264(candidate):
                return EncoderInfo(path=candidate, kind="ffmpeg")
            continue
        return EncoderInfo(path=candidate, kind="x264")
    return None


@dataclasses.dataclass(frozen=True)
class BrowserHostAvailability:
    """Whether this runner can serve remote browser tabs, and why not.

    :param status: ``available``, ``disabled``, ``not_installed`` or ``encoder_missing``.
    :param message: User-facing explanation for any status but ``available``.
    :param binary: Located host binary.
    :param encoder: Located encoder.
    """

    status: BrowserHostStatus
    message: str
    binary: Path | None = None
    encoder: EncoderInfo | None = None

    def to_dict(self) -> dict[str, object]:
        """Return the ``browser_host`` JSON object the runner reports."""
        payload: dict[str, object] = {"status": self.status}
        if self.message:
            payload["message"] = self.message
        if self.encoder is not None:
            payload["encoder"] = self.encoder.kind
        return payload


def check_availability(settings: BrowserHostSettings) -> BrowserHostAvailability:
    """Resolve the host binary and encoder for *settings*."""
    if not settings.enabled:
        return BrowserHostAvailability(
            status="disabled", message=f"Remote browser is off; set {ENV_ENABLED}=1 to enable it."
        )
    binary = locate_host_binary(settings)
    if binary is None:
        where = settings.binary or settings.runtime_dir or settings.browser_dir / "runtime"
        return BrowserHostAvailability(
            status="not_installed",
            message=(
                f"{HOST_BINARY_NAME} was not found (looked in {where} and PATH). "
                f"Set {ENV_HOST_BIN} or {ENV_RUNTIME_DIR}."
            ),
        )
    encoder = detect_encoder(settings)
    if encoder is None:
        return BrowserHostAvailability(
            status="encoder_missing",
            message=(
                "The remote browser needs an H.264 encoder on this machine: install x264 "
                "(apt install x264, brew install x264) or ffmpeg built with libx264."
            ),
            binary=binary,
        )
    return BrowserHostAvailability(status="available", message="", binary=binary, encoder=encoder)


_hello_capabilities_cache: list[str] | None = None


def remote_browser_hello_capabilities() -> list[str]:
    """Return the hello capabilities for the remote browser, computed once per process.

    :returns: ``[CAP_REMOTE_BROWSER]`` when the host can run here, else ``[]``.
    """
    global _hello_capabilities_cache
    if _hello_capabilities_cache is None:
        availability = check_availability(BrowserHostSettings.from_env())
        if availability.status != "available":
            _logger.info("remote browser not advertised: %s", availability.message)
        _hello_capabilities_cache = (
            [CAP_REMOTE_BROWSER] if availability.status == "available" else []
        )
    return list(_hello_capabilities_cache)


@dataclasses.dataclass(frozen=True)
class HostState:
    """Contents of a profile's ``host.json``, written by a listening host.

    :param pid: Host process id.
    :param socket: Path of the host's ``host.sock``.
    :param profile: Profile name.
    :param cdp_port: Loopback DevTools port, if CEF opened one.
    :param version: Host version string.
    """

    pid: int
    socket: Path
    profile: str
    cdp_port: int | None
    version: str

    @classmethod
    def from_json(cls, raw: Mapping[str, object], *, source: Path) -> HostState:
        """Validate a decoded ``host.json``.

        :raises BrowserHostError: ``internal`` when a required field is missing.
        """
        pid = raw.get("pid")
        socket_path = raw.get("socket")
        profile = raw.get("profile")
        cdp_port = raw.get("cdp_port")
        version = raw.get("version")
        if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
            raise BrowserHostError("internal", f"{source}: 'pid' must be a positive integer")
        if not isinstance(socket_path, str) or not socket_path:
            raise BrowserHostError("internal", f"{source}: 'socket' must be a path")
        if not isinstance(profile, str) or not profile:
            raise BrowserHostError("internal", f"{source}: 'profile' must be a string")
        port = cdp_port if isinstance(cdp_port, int) and not isinstance(cdp_port, bool) else None
        return cls(
            pid=pid,
            socket=Path(socket_path),
            profile=profile,
            cdp_port=port,
            version=version if isinstance(version, str) else "",
        )


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


_PROCESS_EXIT_WAIT_S: Final[float] = 3.0


def _names_profile_dir(command: str, profile_dir: Path) -> bool:
    """Whether *command* passes *profile_dir* as Chromium's or the host's profile flag."""
    tokens = command.split()
    for directory in {str(profile_dir), str(profile_dir.resolve())}:
        if f"--user-data-dir={directory}" in tokens or f"--profile-dir={directory}" in tokens:
            return True
        for index, token in enumerate(tokens[:-1]):
            if token == "--profile-dir" and tokens[index + 1] == directory:
                return True
    return False


async def terminate_profile_processes(profile_dir: Path) -> list[int]:
    """SIGTERM (then SIGKILL) processes whose command line names *profile_dir*.

    Matches only an exact ``--user-data-dir=<dir>`` or ``--profile-dir <dir>``
    argument, so a sibling profile such as ``work2`` is never touched.

    :returns: The pids that were signalled.
    :raises OSError: When ``ps`` cannot be run.
    """
    process = await asyncio.create_subprocess_exec(
        "ps",
        # -ww: never truncate the command line (ps otherwise cuts it to a width).
        "-axww",
        "-o",
        "pid=,command=",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await process.communicate()
    if process.returncode != 0:
        raise OSError(f"ps failed ({process.returncode}): {stderr.decode(errors='replace')}")
    own_pid = os.getpid()
    targets: list[int] = []
    for line in stdout.decode(errors="replace").splitlines():
        pid_text, _, command = line.strip().partition(" ")
        if (
            pid_text.isdigit()
            and int(pid_text) != own_pid
            and _names_profile_dir(command, profile_dir)
        ):
            targets.append(int(pid_text))
    for pid in targets:
        with contextlib.suppress(ProcessLookupError):
            os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + _PROCESS_EXIT_WAIT_S
    while time.monotonic() < deadline and any(_pid_alive(pid) for pid in targets):
        await asyncio.sleep(_HOST_START_POLL_S)
    for pid in targets:
        if _pid_alive(pid):
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, signal.SIGKILL)
    return targets


def _new_request_id() -> str:
    return f"r_{secrets.token_hex(6)}"


async def _close_writer(writer: asyncio.StreamWriter) -> None:
    writer.close()
    try:
        await writer.wait_closed()
    except (ConnectionError, BrokenPipeError) as exc:
        # The peer already reset the socket; the connection is gone either way.
        _logger.debug("browser host socket closed abruptly: %r", exc)


async def host_request(
    socket_path: Path,
    op: str,
    args: Mapping[str, object] | None = None,
    *,
    timeout_s: float = _DEFAULT_HOST_REQUEST_TIMEOUT_S,
) -> dict[str, object]:
    """Send one control request to a host and return its result.

    :param socket_path: The host's ``host.sock``.
    :param op: Operation, e.g. ``"tabs.list"``.
    :param args: Operation arguments.
    :param timeout_s: Deadline for connect plus response.
    :returns: The response's ``result`` object.
    :raises BrowserHostError: With the host's error code, or ``unavailable``
        when the socket is unreachable, times out or closes early.
    :raises HostProtocolError: When the host breaks the framing.
    """
    request_id = _new_request_id()
    try:
        async with asyncio.timeout(timeout_s):
            reader, writer = await asyncio.open_unix_connection(str(socket_path))
            try:
                writer.write(encode_text_frame({"type": "control"}))
                writer.write(
                    encode_text_frame(
                        {"type": "request", "id": request_id, "op": op, "args": dict(args or {})}
                    )
                )
                await writer.drain()
                return await _read_response(reader, request_id, op)
            finally:
                await _close_writer(writer)
    except TimeoutError as exc:
        raise BrowserHostError("unavailable", f"browser host did not answer {op!r}") from exc
    except (ConnectionError, FileNotFoundError) as exc:
        raise BrowserHostError(
            "unavailable", f"browser host socket {socket_path} is unreachable: {exc}"
        ) from exc


async def _read_response(
    reader: asyncio.StreamReader, request_id: str, op: str
) -> dict[str, object]:
    while True:
        frame = await read_host_frame(reader)
        if frame is None:
            raise BrowserHostError("unavailable", f"browser host closed before answering {op!r}")
        if frame.kind is HostFrameKind.CLOSE:
            code, reason = decode_close_payload(frame.payload)
            raise BrowserHostError(
                "unavailable", f"browser host closed the control channel ({code}: {reason})"
            )
        if frame.kind is not HostFrameKind.TEXT:
            raise HostProtocolError("browser host sent binary on a control channel")
        try:
            message = json.loads(frame.payload)
        except ValueError as exc:
            raise HostProtocolError("browser host sent invalid JSON") from exc
        if not isinstance(message, dict):
            raise HostProtocolError("browser host sent a non-object message")
        if message.get("type") != "response" or message.get("id") != request_id:
            continue
        if message.get("ok") is True:
            result = message.get("result", {})
            if not isinstance(result, dict):
                raise HostProtocolError(f"browser host {op!r} result is not an object")
            return result
        error = message.get("error")
        code = error.get("code") if isinstance(error, dict) else None
        detail = error.get("message") if isinstance(error, dict) else None
        known: tuple[BrowserHostErrorCode, ...] = (
            "not_found",
            "invalid_input",
            "internal",
            "unavailable",
        )
        mapped: BrowserHostErrorCode = code if code in known else "internal"
        raise BrowserHostError(
            mapped, detail if isinstance(detail, str) else f"browser host {op!r} failed"
        )


def _tab_records(result: Mapping[str, object], op: str) -> list[dict[str, object]]:
    tabs = result.get("tabs")
    if not isinstance(tabs, list) or not all(isinstance(tab, dict) for tab in tabs):
        raise HostProtocolError(f"browser host {op!r} result has no 'tabs' list")
    return [dict(tab) for tab in tabs]


def _tab_record(result: Mapping[str, object], op: str) -> dict[str, object]:
    """``tabs.create`` and ``tabs.navigate`` answer with the tab record itself."""
    if not isinstance(result.get("id"), str):
        raise HostProtocolError(f"browser host {op!r} result is not a tab record")
    return dict(result)


class BrowserHostManager:
    """Owns this runner's view of the per-profile browser hosts.

    :param settings: Resolved settings.
    """

    def __init__(self, settings: BrowserHostSettings) -> None:
        self.settings = settings
        self._availability: BrowserHostAvailability | None = None
        self._profile_locks: dict[str, asyncio.Lock] = {}
        self._tab_profiles: dict[str, str] = {}

    async def availability(self) -> BrowserHostAvailability:
        """Return (and cache) whether hosts can run on this machine."""
        if self._availability is None:
            self._availability = await asyncio.to_thread(check_availability, self.settings)
        return self._availability

    async def require_available(self) -> BrowserHostAvailability:
        """Return the availability, raising unless it is ``available``.

        :raises BrowserHostError: ``unavailable`` with the reason.
        """
        availability = await self.availability()
        if availability.status != "available":
            raise BrowserHostError("unavailable", availability.message)
        return availability

    def profile_dir(self, profile: str) -> Path:
        """``<data>/browser/profiles/<profile>``: the profile's CEF cache and host files."""
        return self.settings.browser_dir / "profiles" / validate_browser_profile_name(profile)

    def socket_path(self, profile: str) -> Path:
        """Pick the ``host.sock`` path for *profile*, short enough for ``sun_path``."""
        validate_browser_profile_name(profile)
        preferred = self.profile_dir(profile) / "host.sock"
        if len(os.fsencode(preferred)) <= _MAX_SOCKET_PATH_BYTES:
            return preferred
        digest = hashlib.sha256(os.fsencode(self.settings.browser_dir)).hexdigest()[:12]
        return (
            Path(tempfile.gettempdir())
            / f"omnigent-browser-{os.getuid()}"
            / f"{digest}-{profile}.sock"
        )

    def _state_path(self, profile: str) -> Path:
        return self.profile_dir(profile) / "host.json"

    def read_state(self, profile: str) -> HostState | None:
        """Read *profile*'s ``host.json``; ``None`` when the host is not running.

        :raises BrowserHostError: ``internal`` when the file is unreadable or malformed.
        """
        path = self._state_path(profile)
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None
        except (OSError, ValueError) as exc:
            raise BrowserHostError("internal", f"cannot read {path}: {exc}") from exc
        if not isinstance(raw, dict):
            raise BrowserHostError("internal", f"{path} is not a JSON object")
        return HostState.from_json(raw, source=path)

    async def _live_state(self, profile: str) -> HostState | None:
        """Return the state of a running, answering host for *profile*, else ``None``."""
        state = self.read_state(profile)
        if state is None:
            return None
        if not _pid_alive(state.pid):
            await self._clear_stale_host(profile, state)
            return None
        try:
            await host_request(state.socket, "health")
        except BrowserHostError as exc:
            if exc.code != "unavailable":
                raise
            _logger.warning("browser host for profile %s is not answering: %s", profile, exc)
            return None
        return state

    async def _clear_stale_host(self, profile: str, state: HostState) -> None:
        """Clean up after a host that died without removing its ``host.json``.

        Its Chromium helpers can outlive it; terminate only processes whose
        command line names this profile's directory, then drop the stale file.
        """
        profile_dir = self.profile_dir(profile)
        reaped = await terminate_profile_processes(profile_dir)
        _logger.warning(
            "browser host %s for profile %s died without cleanup; terminated helpers %s",
            state.pid,
            profile,
            reaped,
        )
        self._state_path(profile).unlink(missing_ok=True)

    def profile_names(self) -> list[str]:
        """Profiles with a directory on this machine, plus ``default``."""
        names = {DEFAULT_BROWSER_PROFILE}
        profiles_root = self.settings.browser_dir / "profiles"
        if profiles_root.is_dir():
            for child in profiles_root.iterdir():
                if child.is_dir():
                    try:
                        names.add(validate_browser_profile_name(child.name))
                    except ValueError:
                        continue
        return sorted(names)

    async def list_profiles(self) -> list[dict[str, object]]:
        """Describe each profile: ``{"name", "default", "running"}``."""
        profiles: list[dict[str, object]] = []
        for name in self.profile_names():
            state = self.read_state(name)
            profiles.append(
                {
                    "name": name,
                    "default": name == DEFAULT_BROWSER_PROFILE,
                    "running": state is not None and _pid_alive(state.pid),
                }
            )
        return profiles

    async def ensure_host(self, profile: str) -> HostState:
        """Return a live host for *profile*, spawning or respawning one if needed.

        :raises BrowserHostError: ``unavailable`` when the host cannot start,
            ``invalid_input`` for a bad profile name.
        """
        try:
            validate_browser_profile_name(profile)
        except ValueError as exc:
            raise BrowserHostError("invalid_input", str(exc)) from exc
        availability = await self.require_available()
        lock = self._profile_locks.setdefault(profile, asyncio.Lock())
        async with lock:
            state = await self._live_state(profile)
            if state is not None:
                return state
            return await self._spawn(profile, availability)

    async def _spawn(self, profile: str, availability: BrowserHostAvailability) -> HostState:
        binary = availability.binary
        if binary is None:
            raise BrowserHostError("unavailable", availability.message)
        profile_dir = self.profile_dir(profile)
        socket_path = self.socket_path(profile)
        for directory in (self.settings.browser_dir, profile_dir, socket_path.parent):
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.chmod(directory, 0o700)
        argv = [
            str(binary),
            "--profile",
            profile,
            "--profile-dir",
            str(profile_dir),
            "--socket",
            str(socket_path),
        ]
        if availability.encoder is not None:
            argv += ["--encoder", str(availability.encoder.path)]
        argv += list(self.settings.extra_args)
        log_path = profile_dir / "host.log"
        _logger.info("starting browser host for profile %s: %s", profile, shlex.join(argv))
        with log_path.open("ab") as log_file:
            # A new session keeps the host (and the profile's logins) alive
            # across runner restarts; the host exits on its own when idle.
            process = await asyncio.create_subprocess_exec(
                *argv,
                stdin=asyncio.subprocess.DEVNULL,
                stdout=log_file,
                stderr=log_file,
                start_new_session=True,
            )
        return await self._wait_for_start(profile, process, log_path)

    async def _wait_for_start(
        self, profile: str, process: asyncio.subprocess.Process, log_path: Path
    ) -> HostState:
        deadline = time.monotonic() + self.settings.start_timeout_s
        while time.monotonic() < deadline:
            state = self.read_state(profile)
            if state is not None and _pid_alive(state.pid):
                # Another runner's host may have won the profile lock; use it.
                try:
                    await host_request(state.socket, "health")
                except BrowserHostError as exc:
                    if exc.code != "unavailable":
                        raise
                else:
                    return state
            if process.returncode is not None:
                state = await self._live_state(profile)
                if state is not None:
                    return state
                raise BrowserHostError(
                    "unavailable",
                    f"browser host for profile {profile!r} exited with code "
                    f"{process.returncode}: {_log_tail(log_path)}",
                )
            await asyncio.sleep(_HOST_START_POLL_S)
        process.kill()
        await process.wait()
        raise BrowserHostError(
            "unavailable",
            f"browser host for profile {profile!r} did not start within "
            f"{self.settings.start_timeout_s:g}s: {_log_tail(log_path)}",
        )

    async def running_hosts(self) -> list[HostState]:
        """States of every profile host that is running and answering."""
        states: list[HostState] = []
        for name in self.profile_names():
            state = await self._live_state(name)
            if state is not None:
                states.append(state)
        return states

    async def list_tabs(self, session_id: str) -> list[dict[str, object]]:
        """List *session_id*'s tabs across running hosts, without starting any.

        :raises BrowserHostError: When a running host rejects the request.
        """
        tabs: list[dict[str, object]] = []
        for state in await self.running_hosts():
            result = await host_request(state.socket, "tabs.list", {"session_id": session_id})
            for tab in _tab_records(result, "tabs.list"):
                tab.setdefault("profile", state.profile)
                self._tab_profiles[str(tab["id"])] = state.profile
                tabs.append(tab)
        return tabs

    async def create_tab(
        self,
        session_id: str,
        *,
        profile: str = DEFAULT_BROWSER_PROFILE,
        url: str | None = None,
        created_by: Literal["user", "agent"] = "user",
        viewport: Mapping[str, object] | None = None,
    ) -> dict[str, object]:
        """Open a tab for *session_id* in *profile*'s host, starting it if needed.

        :param viewport: Optional ``{"width", "height", "dpr"}``.
        :returns: The host's tab record.
        :raises BrowserHostError: When the host is unavailable or rejects the tab.
        """
        state = await self.ensure_host(profile)
        args: dict[str, object] = {"session_id": session_id, "created_by": created_by}
        if url:
            args["url"] = url
        if viewport:
            args.update(viewport)
        result = await host_request(
            state.socket, "tabs.create", args, timeout_s=_TAB_CREATE_TIMEOUT_S
        )
        tab = _tab_record(result, "tabs.create")
        tab.setdefault("profile", state.profile)
        self._tab_profiles[str(tab["id"])] = state.profile
        return tab

    async def resolve_tab(
        self, session_id: str, tab_id: str
    ) -> tuple[HostState, dict[str, object]] | None:
        """Find *tab_id* among *session_id*'s tabs; ``None`` when it does not exist.

        A tab of another session is reported as missing.
        """
        cached_profile = self._tab_profiles.get(tab_id)
        candidates: list[HostState] = []
        if cached_profile is not None:
            cached_state = await self._live_state(cached_profile)
            if cached_state is not None:
                candidates.append(cached_state)
        if not candidates:
            candidates = await self.running_hosts()
        for state in candidates:
            result = await host_request(state.socket, "tabs.list", {"session_id": session_id})
            for tab in _tab_records(result, "tabs.list"):
                if tab.get("id") == tab_id:
                    tab.setdefault("profile", state.profile)
                    self._tab_profiles[tab_id] = state.profile
                    return state, tab
        self._tab_profiles.pop(tab_id, None)
        return None

    async def close_tab(self, session_id: str, tab_id: str) -> bool:
        """Close one of *session_id*'s tabs; ``False`` when it does not exist."""
        resolved = await self.resolve_tab(session_id, tab_id)
        if resolved is None:
            return False
        state, _tab = resolved
        try:
            await host_request(state.socket, "tabs.close", {"tab_id": tab_id})
        except BrowserHostError as exc:
            if exc.code == "not_found":
                return False
            raise
        finally:
            self._tab_profiles.pop(tab_id, None)
        return True

    async def close_session_tabs(self, session_id: str) -> list[str]:
        """Close every tab *session_id* owns on running hosts.

        Every profile is tried even when one fails, so one broken host cannot
        keep the session's tabs open on the others.

        :returns: Ids of the closed tabs.
        :raises BrowserCleanupError: After trying every profile, when any failed.
        """
        closed: list[str] = []
        failures: dict[str, str] = {}
        for profile in self.profile_names():
            try:
                state = await self._live_state(profile)
                if state is None:
                    continue
                listed = await host_request(state.socket, "tabs.list", {"session_id": session_id})
                tab_ids = [str(tab["id"]) for tab in _tab_records(listed, "tabs.list")]
                await host_request(state.socket, "tabs.close_session", {"session_id": session_id})
            except (BrowserHostError, HostProtocolError, OSError) as exc:
                failures[profile] = str(exc)
                continue
            for tab_id in tab_ids:
                self._tab_profiles.pop(tab_id, None)
            closed.extend(tab_ids)
        if failures:
            raise BrowserCleanupError(session_id, closed, failures)
        return closed

    async def open_attach(
        self, state: HostState, tab_id: str, mode: BrowserAttachMode
    ) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
        """Open an attach connection to *tab_id* and send its preamble.

        :raises BrowserHostError: ``unavailable`` when the socket is unreachable.
        """
        try:
            reader, writer = await asyncio.open_unix_connection(str(state.socket))
        except (ConnectionError, FileNotFoundError) as exc:
            raise BrowserHostError(
                "unavailable", f"browser host socket {state.socket} is unreachable: {exc}"
            ) from exc
        writer.write(
            encode_text_frame(
                {
                    "type": "attach",
                    "protocol": REMOTE_BROWSER_PROTOCOL_VERSION,
                    "tab_id": tab_id,
                    "mode": mode,
                }
            )
        )
        await writer.drain()
        return reader, writer


def _log_tail(log_path: Path) -> str:
    try:
        with log_path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - _HOST_LOG_TAIL_BYTES))
            tail = handle.read().decode("utf-8", errors="replace").strip()
    except OSError as exc:
        return f"(host log {log_path} unreadable: {exc})"
    return tail or f"(host log {log_path} is empty)"


def default_manager() -> BrowserHostManager:
    """Build a manager from the runner environment."""
    return BrowserHostManager(BrowserHostSettings.from_env())


__all__ = [
    "CAP_REMOTE_BROWSER",
    "MAX_HOST_FRAME_BYTES",
    "BrowserCleanupError",
    "BrowserHostAvailability",
    "BrowserHostError",
    "BrowserHostManager",
    "BrowserHostSettings",
    "EncoderInfo",
    "HostFrame",
    "HostFrameKind",
    "HostFrameTooLargeError",
    "HostProtocolError",
    "HostState",
    "check_availability",
    "decode_close_payload",
    "default_manager",
    "detect_encoder",
    "encode_close_payload",
    "encode_host_frame",
    "encode_text_frame",
    "host_request",
    "locate_host_binary",
    "read_host_frame",
    "remote_browser_hello_capabilities",
]
