"""Stand-in for ``omnigent-browser-host`` that speaks the v1 runner/host contract.

Run as ``python fake_browser_host.py --profile P --profile-dir D --socket S``,
which matches the real host's CLI (section 5.7 of
``apps/apple/docs/remote-browser-design.md``). It takes the profile lock,
writes ``host.json``, answers control ops, and on attach replays the shared
fixtures in ``client-core/fixtures/remote_browser/``: after the client
``hello`` it sends ``hello``, ``control``, ``viewport``, ``nav``, ``cursor``,
``text_input``, then the fixture IDR and delta frames.

Every client message an attach delivers is recorded per tab. The extra
control op ``fake.received {tab_id}`` returns them, so tests can check what
reached the host. Only the standard library is used.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import fcntl
import json
import os
import secrets
import signal
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

FIXTURES_DIR = Path(__file__).resolve().parents[2] / "client-core" / "fixtures" / "remote_browser"
HOST_VERSION = "0.0.0-fake"
KIND_TEXT = 1
KIND_BINARY = 2
KIND_CLOSE = 3
MAX_FRAME_BYTES = 16 * 1024 * 1024


def _frame(kind: int, payload: bytes) -> bytes:
    return len(payload).to_bytes(4, "little") + bytes((kind,)) + payload


def _text(message: dict[str, object]) -> bytes:
    return _frame(KIND_TEXT, json.dumps(message, separators=(",", ":")).encode("utf-8"))


def _close(code: int, reason: str) -> bytes:
    return _frame(KIND_CLOSE, code.to_bytes(2, "little") + reason.encode("utf-8"))


def _fixture(relative: str) -> dict[str, object]:
    loaded = json.loads((FIXTURES_DIR / relative).read_text(encoding="utf-8"))
    if not isinstance(loaded, dict):
        raise ValueError(f"fixture {relative} is not an object")
    return loaded


async def _read_frame(reader: asyncio.StreamReader) -> tuple[int, bytes] | None:
    try:
        prefix = await reader.readexactly(5)
    except asyncio.IncompleteReadError:
        return None
    length = int.from_bytes(prefix[:4], "little")
    if length > MAX_FRAME_BYTES:
        raise ValueError("frame too large")
    try:
        return prefix[4], await reader.readexactly(length)
    except asyncio.IncompleteReadError:
        return None


@dataclass
class _Tab:
    record: dict[str, object]
    received: list[dict[str, object]] = field(default_factory=list)
    attached: set[asyncio.StreamWriter] = field(default_factory=set)


class FakeBrowserHost:
    """In-memory tab table plus the socket server."""

    def __init__(self, profile: str, socket_path: Path, profile_dir: Path, idle_s: float) -> None:
        self.profile = profile
        self.socket_path = socket_path
        self.profile_dir = profile_dir
        self.idle_s = idle_s
        self.tabs: dict[str, _Tab] = {}
        self.connections = 0
        self.last_activity = time.monotonic()
        self.stopping = asyncio.Event()

    def _new_tab(self, args: dict[str, object]) -> dict[str, object]:
        session_id = args.get("session_id")
        if not isinstance(session_id, str) or not session_id:
            raise _OpError("invalid_input", "tabs.create needs a session_id")
        url = args.get("url") if isinstance(args.get("url"), str) else "about:blank"
        record = _fixture("runner_host/response_tabs_create.json")["result"]
        assert isinstance(record, dict)
        record = {
            **record,
            "id": f"btab_{secrets.token_hex(4)}",
            "session_id": session_id,
            "url": url,
            "title": "" if url == "about:blank" else record["title"],
            "profile": self.profile,
            "created_by": args.get("created_by", "user"),
        }
        self.tabs[str(record["id"])] = _Tab(record=record)
        return record

    def _tab(self, args: dict[str, object]) -> _Tab:
        tab_id = args.get("tab_id")
        tab = self.tabs.get(tab_id) if isinstance(tab_id, str) else None
        if tab is None:
            raise _OpError("not_found", f"no tab {tab_id}")
        return tab

    async def _close_tab(self, tab_id: str) -> None:
        tab = self.tabs.pop(tab_id)
        for writer in list(tab.attached):
            writer.write(_text({"type": "tab_closed", "reason": "closed"}))
            writer.write(_close(4404, "tab closed"))
            with contextlib.suppress(ConnectionError):
                await writer.drain()
            writer.close()

    async def handle_op(self, op: str, args: dict[str, object]) -> dict[str, object]:
        if op == "health":
            return {
                "version": HOST_VERSION,
                "profile": self.profile,
                "cdp_port": None,
                "tabs": len(self.tabs),
            }
        if op == "tabs.list":
            session_id = args.get("session_id")
            return {
                "tabs": [
                    tab.record
                    for tab in self.tabs.values()
                    if session_id is None or tab.record["session_id"] == session_id
                ]
            }
        if op == "tabs.create":
            return self._new_tab(args)
        if op == "tabs.navigate":
            tab = self._tab(args)
            tab.record["url"] = args.get("url")
            return tab.record
        if op == "tabs.close":
            await self._close_tab(str(self._tab(args).record["id"]))
            return {"closed": True}
        if op == "tabs.close_session":
            doomed = [
                tab_id
                for tab_id, tab in self.tabs.items()
                if tab.record["session_id"] == args.get("session_id")
            ]
            for tab_id in doomed:
                await self._close_tab(tab_id)
            return {"closed": len(doomed)}
        if op == "host.shutdown":
            self.stopping.set()
            return {}
        if op == "fake.received":
            return {"messages": self._tab(args).received}
        raise _OpError("invalid_input", f"unknown op {op!r}")

    async def serve_connection(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        self.connections += 1
        try:
            first = await _read_frame(reader)
            if first is None:
                return
            kind, payload = first
            preamble = json.loads(payload) if kind == KIND_TEXT else None
            kind_name = preamble.get("type") if isinstance(preamble, dict) else None
            if kind_name == "control":
                await self._serve_control(reader, writer)
            elif kind_name == "attach" and isinstance(preamble, dict):
                await self._serve_attach(preamble, reader, writer)
            else:
                writer.write(_close(1002, "expected attach or control"))
                await writer.drain()
        finally:
            self.connections -= 1
            self.last_activity = time.monotonic()
            writer.close()

    async def _serve_control(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        while (frame := await _read_frame(reader)) is not None:
            request = json.loads(frame[1])
            request_id = request.get("id")
            try:
                result = await self.handle_op(str(request.get("op")), request.get("args") or {})
            except _OpError as exc:
                response = {
                    "type": "response",
                    "id": request_id,
                    "ok": False,
                    "error": {"code": exc.code, "message": exc.message},
                }
            else:
                response = {"type": "response", "id": request_id, "ok": True, "result": result}
            writer.write(_text(response))
            await writer.drain()

    async def _serve_attach(
        self,
        preamble: dict[str, object],
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        if preamble.get("protocol") != 1:
            writer.write(_close(4426, "protocol unsupported"))
            await writer.drain()
            return
        tab = self.tabs.get(str(preamble.get("tab_id")))
        if tab is None:
            writer.write(_close(4404, "unknown tab"))
            await writer.drain()
            return
        mode = preamble.get("mode")
        tab.attached.add(writer)
        try:
            while (frame := await _read_frame(reader)) is not None:
                kind, payload = frame
                if kind == KIND_CLOSE:
                    return
                if kind != KIND_TEXT:
                    continue
                message = json.loads(payload)
                tab.received.append(message)
                if message.get("type") == "hello":
                    await self._send_setup(tab, str(mode), writer)
                elif message.get("type") == "ping":
                    writer.write(_text({"type": "pong", "nonce": message.get("nonce")}))
                elif message.get("type") == "keyframe_request":
                    writer.write(_frame(KIND_BINARY, _media("h264_idr.bin")))
                await writer.drain()
        finally:
            tab.attached.discard(writer)

    async def _send_setup(self, tab: _Tab, mode: str, writer: asyncio.StreamWriter) -> None:
        hello = {
            **_fixture("messages/host_to_client/hello.json"),
            "tab_id": tab.record["id"],
            "profile": self.profile,
            "host_version": HOST_VERSION,
            "mode": mode,
        }
        nav = {**_fixture("messages/host_to_client/nav.json"), "url": tab.record["url"]}
        for message in (
            hello,
            _fixture("messages/host_to_client/control_agent.json"),
            _fixture("messages/host_to_client/viewport.json"),
            nav,
            _fixture("messages/host_to_client/cursor.json"),
            _fixture("messages/host_to_client/text_input_none.json"),
        ):
            writer.write(_text(message))
        writer.write(_frame(KIND_BINARY, _media("h264_idr.bin")))
        writer.write(_frame(KIND_BINARY, _media("h264_delta.bin")))

    async def idle_watch(self) -> None:
        while not self.stopping.is_set():
            await asyncio.sleep(0.2)
            idle = not self.tabs and self.connections == 0
            if idle and time.monotonic() - self.last_activity > self.idle_s:
                self.stopping.set()


class _OpError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _media(name: str) -> bytes:
    return (FIXTURES_DIR / "binary_frames" / name).read_bytes()


async def _main(options: argparse.Namespace) -> int:
    profile_dir = Path(options.profile_dir)
    socket_path = Path(options.socket)
    profile_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_handle = (profile_dir / "host.lock").open("w")
    try:
        fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"profile {options.profile} is locked by another host", file=sys.stderr)
        return 3
    exit_code = os.environ.get("FAKE_BROWSER_HOST_EXIT_CODE")
    if exit_code:
        print("fake host told to fail at startup", file=sys.stderr)
        return int(exit_code)
    host = FakeBrowserHost(options.profile, socket_path, profile_dir, options.idle_exit_seconds)
    socket_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with contextlib.suppress(FileNotFoundError):
        socket_path.unlink()
    server = await asyncio.start_unix_server(host.serve_connection, path=str(socket_path))
    os.chmod(socket_path, 0o600)
    state_path = profile_dir / "host.json"
    temp_path = profile_dir / "host.json.tmp"
    temp_path.write_text(
        json.dumps(
            {
                "pid": os.getpid(),
                "socket": str(socket_path),
                "cdp_port": None,
                "version": HOST_VERSION,
                "profile": options.profile,
                "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "encoder": {"path": options.encoder or "", "kind": "x264"},
            }
        ),
        encoding="utf-8",
    )
    temp_path.replace(state_path)
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(signum, host.stopping.set)
    watcher = asyncio.create_task(host.idle_watch())
    try:
        await host.stopping.wait()
    finally:
        watcher.cancel()
        server.close()
        state_path.unlink(missing_ok=True)
        with contextlib.suppress(FileNotFoundError):
            socket_path.unlink()
    return 0


def install_fake_browser_host(root: Path) -> tuple[Path, Path]:
    """Write an executable wrapper that runs this fake, plus a placeholder ``x264``.

    :param root: Empty directory for the two executables.
    :returns: ``(host_binary, encoder)`` for ``BrowserHostSettings``.
    """
    root.mkdir(parents=True, exist_ok=True)
    binary = root / "omnigent-browser-host"
    binary.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{Path(__file__).resolve()}" "$@"\n')
    encoder = root / "x264"
    encoder.write_text("#!/bin/sh\nexit 0\n")
    for path in (binary, encoder):
        path.chmod(0o755)
    return binary, encoder


def stop_fake_browser_hosts(browser_dir: Path, *, timeout_s: float = 5.0) -> None:
    """SIGTERM every host with a ``host.json`` under *browser_dir* and wait for it to stop.

    :raises TimeoutError: When a host outlives *timeout_s*.
    """
    for state_path in browser_dir.glob("profiles/*/host.json"):
        pid = json.loads(state_path.read_text(encoding="utf-8"))["pid"]
        with contextlib.suppress(ProcessLookupError):
            os.kill(pid, signal.SIGTERM)
        # The fake removes host.json as it exits; a reaped-later zombie still answers kill(0).
        deadline = time.monotonic() + timeout_s
        while state_path.exists():
            if time.monotonic() > deadline:
                raise TimeoutError(f"fake browser host {pid} did not exit")
            time.sleep(0.02)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="default")
    parser.add_argument("--profile-dir", required=True)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--encoder", default=None)
    parser.add_argument("--cdp-port", type=int, default=0)
    parser.add_argument("--headless-mode", default="ozone")
    parser.add_argument("--idle-exit-seconds", type=float, default=600.0)
    parser.add_argument("--no-sandbox", action="store_true")
    return asyncio.run(_main(parser.parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())
