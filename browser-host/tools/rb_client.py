#!/usr/bin/env python3
"""A small client for omnigent-browser-host's host.sock (design doc section 5.7).

Library use: ``ControlClient`` for the runner control API, ``AttachClient`` for one tab's
client protocol. Command-line use::

    rb_client.py --socket S health
    rb_client.py --socket S create --url https://example.com
    rb_client.py --socket S list
    rb_client.py --socket S watch TAB_ID --seconds 5 --out stream.h264
    rb_client.py --socket S close TAB_ID
    rb_client.py --socket S shutdown
"""

from __future__ import annotations

import argparse
import itertools
import json
import socket
import struct
import sys
import time
from dataclasses import dataclass, field
from typing import Any

KIND_TEXT = 1
KIND_BINARY = 2
KIND_CLOSE = 3
MEDIA_HEADER = struct.Struct("<HBBHHIIQ")
FLAG_KEYFRAME = 1
FLAG_NEW_STREAM = 2


class HostError(RuntimeError):
    """A protocol failure or an error response from the host."""


@dataclass
class Closed:
    """The host closed the connection with `code` and `reason`."""

    code: int
    reason: str


@dataclass
class MediaFrame:
    """One binary media message."""

    kind: int
    flags: int
    seq: int
    stream_id: int
    pts_us: int
    payload: bytes
    received_at: float

    @property
    def keyframe(self) -> bool:
        return bool(self.flags & FLAG_KEYFRAME)


class FramedSocket:
    """host.sock framing: u32 LE payload length, u8 kind, payload."""

    def __init__(self, path: str, timeout: float = 10.0) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buffer = b""

    def send(self, kind: int, payload: bytes) -> None:
        self.sock.sendall(struct.pack("<IB", len(payload), kind) + payload)

    def send_json(self, message: dict[str, Any]) -> None:
        self.send(KIND_TEXT, json.dumps(message, separators=(",", ":")).encode())

    def send_close(self, code: int = 1000, reason: str = "") -> None:
        self.send(KIND_CLOSE, struct.pack("<H", code) + reason.encode())

    def receive(self, timeout: float | None = None) -> tuple[int, bytes] | None:
        """Returns the next (kind, payload), or None on timeout. Raises HostError on EOF."""
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            if len(self.buffer) >= 5:
                length, kind = struct.unpack_from("<IB", self.buffer)
                if len(self.buffer) >= 5 + length:
                    payload = self.buffer[5 : 5 + length]
                    self.buffer = self.buffer[5 + length :]
                    return kind, payload
            if deadline is not None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                self.sock.settimeout(remaining)
            try:
                chunk = self.sock.recv(1 << 20)
            except TimeoutError:
                return None
            if not chunk:
                raise HostError("the host closed the socket without a close frame")
            self.buffer += chunk

    def close(self) -> None:
        self.sock.close()


class ControlClient:
    """The runner control API: request/response over a `{"type":"control"}` connection."""

    def __init__(self, path: str) -> None:
        self.conn = FramedSocket(path)
        self.conn.send_json({"type": "control"})
        self.ids = itertools.count(1)

    def request(self, op: str, args: dict[str, Any] | None = None, timeout: float = 30) -> Any:
        request_id = f"r{next(self.ids)}"
        self.conn.send_json({"type": "request", "id": request_id, "op": op, "args": args or {}})
        deadline = time.monotonic() + timeout
        while True:
            frame = self.conn.receive(max(0.0, deadline - time.monotonic()))
            if frame is None:
                raise HostError(f"{op}: no response within {timeout} s")
            kind, payload = frame
            if kind == KIND_CLOSE:
                code = struct.unpack_from("<H", payload)[0]
                raise HostError(f"{op}: control connection closed with {code}")
            message = json.loads(payload)
            if message.get("type") != "response" or message.get("id") != request_id:
                continue
            if not message["ok"]:
                error = message["error"]
                raise HostError(f"{op}: {error['code']}: {error['message']}")
            return message["result"]

    def close(self) -> None:
        self.conn.close()


@dataclass
class AttachState:
    """What an attach connection has seen so far."""

    messages: list[dict[str, Any]] = field(default_factory=list)
    frames: list[MediaFrame] = field(default_factory=list)
    closed: Closed | None = None

    def last(self, message_type: str) -> dict[str, Any] | None:
        for message in reversed(self.messages):
            if message.get("type") == message_type:
                return message
        return None


class AttachClient:
    """One client-protocol connection to a tab. Acks every binary frame on receipt."""

    def __init__(
        self,
        path: str,
        tab_id: str,
        mode: str = "control",
        visible: bool = True,
        features: list[str] | None = None,
    ) -> None:
        self.conn = FramedSocket(path)
        self.conn.send_json({"type": "attach", "protocol": 1, "tab_id": tab_id, "mode": mode})
        self.conn.send_json(
            {
                "type": "hello",
                "protocol": 1,
                "client": "rb_client.py",
                "decoders": ["h264", "jpeg"],
                "mode": mode,
                "visible": visible,
                "features": features or [],
            }
        )
        self.state = AttachState()

    def send(self, message: dict[str, Any]) -> None:
        self.conn.send_json(message)

    def pump(self, seconds: float) -> AttachState:
        """Reads (and acks) everything that arrives within `seconds`."""
        deadline = time.monotonic() + seconds
        while self.state.closed is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            frame = self.conn.receive(remaining)
            if frame is None:
                break
            self._handle(*frame)
        return self.state

    def wait_for(self, predicate: Any, timeout: float, what: str) -> None:
        """Pumps until `predicate(state)` is true; raises HostError on timeout."""
        deadline = time.monotonic() + timeout
        while not predicate(self.state):
            if self.state.closed is not None:
                raise HostError(f"closed ({self.state.closed}) while waiting for {what}")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise HostError(f"timed out waiting for {what}")
            frame = self.conn.receive(min(remaining, 0.25))
            if frame is not None:
                self._handle(*frame)

    def _handle(self, kind: int, payload: bytes) -> None:
        if kind == KIND_TEXT:
            self.state.messages.append(json.loads(payload))
        elif kind == KIND_BINARY:
            magic, version, media_kind, flags, header_len, seq, stream_id, pts = (
                MEDIA_HEADER.unpack_from(payload)
            )
            if magic != 0x4252 or version != 1 or header_len < 24:
                raise HostError(f"malformed media header {payload[:24].hex()}")
            self.state.frames.append(
                MediaFrame(
                    media_kind,
                    flags,
                    seq,
                    stream_id,
                    pts,
                    payload[header_len:],
                    time.monotonic(),
                )
            )
            self.send({"type": "ack", "seq": seq})
        elif kind == KIND_CLOSE:
            code = struct.unpack_from("<H", payload)[0]
            self.state.closed = Closed(code, payload[2:].decode(errors="replace"))
        else:
            raise HostError(f"unknown frame kind {kind}")

    # Input helpers (the connection must hold control).
    def click(self, x: float, y: float) -> None:
        self.send({"type": "mouse", "kind": "move", "x": x, "y": y, "modifiers": 0})
        for kind, modifiers in (("down", 64), ("up", 0)):
            self.send(
                {
                    "type": "mouse",
                    "kind": kind,
                    "x": x,
                    "y": y,
                    "button": "left",
                    "clicks": 1,
                    "modifiers": modifiers,
                }
            )

    def type_text(self, text: str) -> None:
        for character in text:
            code = _dom_code(character)
            base = {"code": code, "key": character, "modifiers": 0, "repeat": False}
            self.send({"type": "key", "kind": "rawkeydown", **base})
            self.send({"type": "key", "kind": "char", "text": character, **base})
            self.send({"type": "key", "kind": "keyup", **base})

    def press(self, code: str, key: str, text: str | None = None) -> None:
        base = {"code": code, "key": key, "modifiers": 0, "repeat": False}
        self.send({"type": "key", "kind": "rawkeydown", **base})
        if text is not None:
            self.send({"type": "key", "kind": "char", "text": text, **base})
        self.send({"type": "key", "kind": "keyup", **base})

    def wheel(self, x: float, y: float, dy: float) -> None:
        self.send(
            {"type": "mouse", "kind": "wheel", "x": x, "y": y, "modifiers": 0, "dx": 0, "dy": dy}
        )

    def close(self) -> None:
        if self.state.closed is None:
            self.conn.send_close(1000, "client detach")
        self.conn.close()


def _dom_code(character: str) -> str:
    if character.isalpha() and character.isascii():
        return "Key" + character.upper()
    if character.isdigit():
        return "Digit" + character
    return {" ": "Space", ".": "Period", "@": "Digit2", "-": "Minus", "_": "Minus"}.get(
        character, "Unidentified"
    )


def h264_stream(frames: list[MediaFrame]) -> bytes:
    """Concatenates the H.264 access units (kind 1) into one Annex-B stream."""
    return b"".join(frame.payload for frame in frames if frame.kind == 1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--socket", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("health")
    sub.add_parser("list")
    sub.add_parser("shutdown")
    create = sub.add_parser("create")
    create.add_argument("--url", default="about:blank")
    create.add_argument("--session", default="cli")
    create.add_argument("--width", type=int, default=1280)
    create.add_argument("--height", type=int, default=800)
    close = sub.add_parser("close")
    close.add_argument("tab_id")
    watch = sub.add_parser("watch")
    watch.add_argument("tab_id")
    watch.add_argument("--seconds", type=float, default=5)
    watch.add_argument("--out")
    args = parser.parse_args()

    if args.command == "watch":
        client = AttachClient(args.socket, args.tab_id, mode="view")
        state = client.pump(args.seconds)
        for message in state.messages:
            print(json.dumps(message))
        print(
            f"{len(state.frames)} media frames, {sum(len(f.payload) for f in state.frames)} bytes"
        )
        if args.out:
            with open(args.out, "wb") as out:
                out.write(h264_stream(state.frames))
        client.close()
        return 0
    control = ControlClient(args.socket)
    if args.command == "health":
        result = control.request("health")
    elif args.command == "list":
        result = control.request("tabs.list")
    elif args.command == "create":
        result = control.request(
            "tabs.create",
            {
                "session_id": args.session,
                "url": args.url,
                "created_by": "user",
                "width": args.width,
                "height": args.height,
            },
        )
    elif args.command == "close":
        result = control.request("tabs.close", {"tab_id": args.tab_id})
    else:
        result = control.request("host.shutdown")
    print(json.dumps(result, indent=2))
    control.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
