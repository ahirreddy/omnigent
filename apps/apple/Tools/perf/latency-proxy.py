#!/usr/bin/env python3
"""A loopback proxy that makes a local server answer like a remote one, and logs every request.

Each chunk waits half the round trip in each direction, in order, so every request and its answer
cost one round trip, and a new connection one more (its handshake). `--mbps` also limits the
bandwidth each way. Every HTTP/1.1 exchange is logged as one JSON line: the method, target,
status, response bytes, when the request reached the proxy and when its answer had reached the
client, in milliseconds from the proxy's start. A WebSocket upgrade or an event stream passes
through after its headers.

    latency-proxy.py serve --listen 6791 --upstream 6790 --rtt-ms 150 --log proxy.jsonl
    latency-proxy.py report proxy.jsonl [--since-path /.well-known/omnigent.json]
    latency-proxy.py report proxy.jsonl --launched EPOCH --signposts signposts.ndjson

With `--launched` (the app's launch, in epoch seconds) and the app's sidebar signposts from
`log stream --signpost --style ndjson`, the report counts from the launch, merges the app's list
events and sidebar builds into the timeline, and says when the first rows and the whole list
showed and what the main thread spent until then.
"""

from __future__ import annotations

import argparse
import asyncio
import collections
import json
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import TextIO
from urllib.parse import parse_qsl, urlsplit

CHUNK = 65_536
# The reads a sidebar is drawn from: sessions pages (folders and pins too), projects and hosts.
SIDEBAR_READS = {"/v1/sessions", "/v1/sessions/projects", "/v1/projects/order", "/v1/hosts"}


@dataclass
class Exchange:
    """One request on a connection and, once it arrives, its answer."""

    connection: int
    method: str
    target: str
    requested_ms: float
    status: int | None = None
    response_bytes: int = 0
    answered_ms: float | None = None
    streaming: bool = False


@dataclass
class Message:
    """An HTTP/1.1 message being read: its head, then a body by length or in chunks."""

    head: bytearray = field(default_factory=bytearray)
    headers: dict[str, str] | None = None
    start_line: str = ""
    remaining: int = 0
    chunked: bool = False
    chunk_state: str = "size"
    body_bytes: int = 0


class HttpParser:
    """Reads one direction of a connection and reports each message's head and end."""

    def __init__(self, on_head, on_end) -> None:
        self.on_head = on_head
        self.on_end = on_end
        self.message = Message()
        self.buffer = bytearray()
        # After an upgrade or an event stream the bytes are no longer HTTP messages.
        self.raw = False

    def feed(self, data: bytes) -> None:
        if self.raw:
            return
        self.buffer += data
        while self.buffer and not self.raw:
            if self.message.headers is None:
                end = self.buffer.find(b"\r\n\r\n")
                if end < 0:
                    return
                head = bytes(self.buffer[:end]).decode("latin-1")
                del self.buffer[: end + 4]
                lines = head.split("\r\n")
                headers = {}
                for line in lines[1:]:
                    name, _, value = line.partition(":")
                    headers[name.strip().lower()] = value.strip()
                self.message.start_line = lines[0]
                self.message.headers = headers
                body = self.on_head(lines[0], headers)
                if body == "raw":
                    self.raw = True
                    return
                if headers.get("transfer-encoding", "").lower() == "chunked":
                    self.message.chunked = True
                else:
                    self.message.remaining = int(headers.get("content-length", "0") or 0)
                    if body == "none":
                        self.message.remaining = 0
                if not self.message.chunked and self.message.remaining == 0:
                    self.finish()
                continue
            if self.message.chunked:
                if not self.read_chunk():
                    return
                continue
            taken = min(len(self.buffer), self.message.remaining)
            del self.buffer[:taken]
            self.message.remaining -= taken
            self.message.body_bytes += taken
            if self.message.remaining == 0:
                self.finish()

    def read_chunk(self) -> bool:
        """Consumes one step of a chunked body; False when more bytes are needed."""
        state = self.message.chunk_state
        if state in ("size", "trailer"):
            end = self.buffer.find(b"\r\n")
            if end < 0:
                return False
            line = bytes(self.buffer[:end]).decode("latin-1")
            del self.buffer[: end + 2]
            if state == "trailer":
                if line == "":
                    self.finish()
                return True
            size = int(line.split(";")[0].strip() or "0", 16)
            if size == 0:
                self.message.chunk_state = "trailer"
            else:
                self.message.remaining = size + 2
                self.message.chunk_state = "data"
            return True
        taken = min(len(self.buffer), self.message.remaining)
        # The chunk's last two bytes are its CRLF, not data.
        data = max(0, min(taken, self.message.remaining - 2))
        del self.buffer[:taken]
        self.message.remaining -= taken
        self.message.body_bytes += data
        if self.message.remaining == 0:
            self.message.chunk_state = "size"
        return True

    def finish(self) -> None:
        message = self.message
        self.message = Message()
        self.on_end(message)


class Link:
    """One client connection: two delayed pumps and the exchanges seen on them."""

    def __init__(self, proxy: Proxy, number: int) -> None:
        self.proxy = proxy
        self.number = number
        self.pending: collections.deque[Exchange] = collections.deque()
        self.requests = HttpParser(self.request_head, lambda _message: None)
        self.responses = HttpParser(self.response_head, self.response_end)
        self.current: Exchange | None = None

    def request_head(self, start_line: str, headers: dict[str, str]) -> str:
        method, _, rest = start_line.partition(" ")
        target = rest.rsplit(" ", 1)[0]
        exchange = Exchange(self.number, method, target, self.proxy.now())
        self.pending.append(exchange)
        if headers.get("upgrade", "").lower() == "websocket":
            return "raw"
        return "body"

    def response_head(self, start_line: str, headers: dict[str, str]) -> str:
        parts = start_line.split(" ")
        status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
        if 100 <= status < 200 and status != 101:
            return "none"
        exchange = self.pending.popleft() if self.pending else None
        self.current = exchange
        if exchange is None:
            return "body"
        exchange.status = status
        if status == 101 or headers.get("content-type", "").startswith("text/event-stream"):
            exchange.streaming = True
            exchange.answered_ms = self.proxy.now()
            self.proxy.record(exchange)
            self.current = None
            return "raw"
        if exchange.method == "HEAD" or status in (204, 304):
            return "none"
        return "body"

    def response_end(self, message: Message) -> None:
        exchange = self.current
        self.current = None
        if exchange is None:
            return
        exchange.response_bytes = message.body_bytes
        exchange.answered_ms = self.proxy.now()
        self.proxy.record(exchange)


class Proxy:
    def __init__(self, args: argparse.Namespace, log: TextIO | None) -> None:
        self.upstream = args.upstream
        self.half_rtt = args.rtt_ms / 2000
        self.bytes_per_second = args.mbps * 125_000 if args.mbps else None
        self.started = time.monotonic()
        # The wall clock at `started`, so a report can line the log up with the app's signposts.
        self.started_epoch = time.time()
        self.connections = 0
        self.log = log

    def now(self) -> float:
        return round((time.monotonic() - self.started) * 1000, 1)

    def record(self, exchange: Exchange) -> None:
        if self.log is None:
            return
        row = {**exchange.__dict__, "started_epoch": self.started_epoch}
        self.log.write(json.dumps(row) + "\n")
        self.log.flush()

    async def handle(self, client_reader, client_writer) -> None:
        self.connections += 1
        link = Link(self, self.connections)
        try:
            upstream_reader, upstream_writer = await asyncio.open_connection(
                "127.0.0.1", self.upstream
            )
        except OSError:
            client_writer.close()
            return
        # A remote connection's handshake costs a round trip before its first request leaves.
        handshake = time.monotonic() + 2 * self.half_rtt
        await asyncio.gather(
            self.pump(client_reader, upstream_writer, link.requests, handshake, on_arrival=True),
            self.pump(upstream_reader, client_writer, link.responses, 0, on_arrival=False),
            return_exceptions=True,
        )

    async def pump(
        self, reader, writer, parser: HttpParser, hold_until: float, *, on_arrival: bool
    ) -> None:
        """Forwards each chunk half a round trip after it arrived (or after `hold_until`), in
        order. Requests are parsed as the app sends them, answers as they reach the app, so the
        log's times are the app's."""
        queue: asyncio.Queue[tuple[float, bytes]] = asyncio.Queue()
        wire_free = 0.0

        async def deliver() -> None:
            while True:
                due, data = await queue.get()
                if not data:
                    break
                delay = due - time.monotonic()
                if delay > 0:
                    await asyncio.sleep(delay)
                try:
                    writer.write(data)
                    await writer.drain()
                except ConnectionError:
                    break
                if not on_arrival:
                    parser.feed(data)
            writer.close()

        delivery = asyncio.create_task(deliver())
        ended = False
        try:
            while True:
                data = await reader.read(CHUNK)
                arrived = time.monotonic()
                if data and on_arrival:
                    parser.feed(data)
                due = max(arrived, hold_until) + self.half_rtt
                if data and self.bytes_per_second:
                    wire_free = max(wire_free, due) + len(data) / self.bytes_per_second
                    due = wire_free
                await queue.put((due, data))
                if not data:
                    ended = True
                    break
        finally:
            # A reset connection ends the delivery too.
            if not ended:
                queue.put_nowait((0.0, b""))
            await delivery


def serve(args: argparse.Namespace) -> None:
    async def main(log: TextIO | None) -> None:
        proxy = Proxy(args, log)
        server = await asyncio.start_server(proxy.handle, "127.0.0.1", args.listen)
        print(f"latency proxy on 127.0.0.1:{args.listen} -> {args.upstream}", flush=True)
        async with server:
            await server.serve_forever()

    if not args.log:
        asyncio.run(main(None))
        return
    with open(args.log, "a", encoding="utf-8") as log:
        asyncio.run(main(log))


def kind(target: str) -> str:
    """A request's name in the report: its path with ids replaced and the list's scope kept."""
    parts = urlsplit(target)
    segments = [
        "{id}" if len(segment) >= 20 or segment.startswith(("conv_", "host_", "prj_")) else segment
        for segment in parts.path.split("/")
    ]
    path = "/".join(segments)
    if path == "/v1/sessions":
        query = dict(parse_qsl(parts.query))
        scope = [f"limit={query.get('limit', '?')}"]
        for name in ("visibility", "include_archived", "pinned", "project", "after"):
            if name in query:
                scope.append(name if name in ("project", "after") else f"{name}={query[name]}")
        path += "?" + "&".join(scope)
    return path


def signposts(path: str) -> list[dict]:
    """The app's sidebar signposts from `log stream --style ndjson --signpost`: each event, and
    each interval at its start with its duration, at wall-clock seconds."""
    opened: dict[tuple, float] = {}
    found = []
    for line in Path(path).read_text().splitlines():
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            # The stream's banner line.
            continue
        signpost = entry.get("signpostType")
        if signpost not in ("begin", "end", "event"):
            continue
        at = datetime.strptime(entry["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
        key = (entry.get("signpostID"), entry.get("signpostName"))
        if signpost == "begin":
            opened[key] = at
            continue
        began = opened.pop(key, at) if signpost == "end" else at
        message = entry.get("eventMessage", "")
        found.append(
            {
                "at": began,
                "ms": (at - began) * 1000,
                "name": entry.get("signpostName", ""),
                "message": message,
                "detail": dict(part.split("=", 1) for part in message.split() if "=" in part),
            }
        )
    return sorted(found, key=lambda mark: mark["at"])


def report(args: argparse.Namespace) -> None:
    rows = [json.loads(line) for line in Path(args.log).read_text().splitlines() if line.strip()]
    rows.sort(key=lambda row: row["requested_ms"])
    start = next(
        (row["requested_ms"] for row in rows if urlsplit(row["target"]).path == args.since_path),
        rows[0]["requested_ms"] if rows else 0,
    )
    # Given the launch's wall-clock time, the requests and the app's signposts count from it.
    launched = args.launched if rows and "started_epoch" in rows[0] else None
    marks = signposts(args.signposts) if args.signposts and launched is not None else []
    marks = [mark for mark in marks if mark["at"] >= (launched or 0)]
    if launched is not None:
        start = (launched - rows[0]["started_epoch"]) * 1000
    lines = []
    sidebar_ends = []
    first_page = None
    for row in rows:
        if row["requested_ms"] < start:
            continue
        begin = row["requested_ms"] - start
        end = (row["answered_ms"] or row["requested_ms"]) - start
        streaming = " (stream)" if row["streaming"] else ""
        name = kind(row["target"])
        lines.append(
            (
                begin,
                f"{begin:7.0f} {end:7.0f} {end - begin:6.0f} {row['response_bytes']:8d}  "
                f"{row['status']} {row['method']} {name}{streaming}",
            )
        )
        if row["method"] == "GET" and name.split("?")[0] in SIDEBAR_READS:
            sidebar_ends.append(end)
            if first_page is None and name.startswith("/v1/sessions?") and "after" not in name:
                first_page = end
    for mark in marks:
        at = (mark["at"] - launched) * 1000
        what = f"app {mark['name']}: {mark['message']}"
        lines.append((at, f"{at:7.0f} {'':>7} {mark['ms']:6.1f} {'':>8}  {what}"))
    print(f"{'from':>7} {'to':>7} {'ms':>6} {'bytes':>8}  status request")
    for _, line in sorted(lines, key=lambda line: line[0]):
        print(line)
    print(f"requests: {sum(row['requested_ms'] >= start for row in rows)}")
    print(f"sidebar reads: {len(sidebar_ends)}")
    answered = "never" if first_page is None else f"{round(first_page)} ms"
    print(f"first sessions page answered: {answered}")
    if sidebar_ends:
        print(f"last sidebar read answered: {round(max(sidebar_ends))} ms")
    if marks:
        summarize(marks, launched, max(sidebar_ends, default=0))


def summarize(marks: list[dict], launched: float, last_read_ms: float) -> None:
    """Prints when the sidebar first had rows and when it had the whole list, from launch, and
    the main thread's time to each."""
    # When each state was drawn (the main queue's turn after its pass), else when it was built.
    drawn = [mark for mark in marks if mark["name"] == "sidebar drawn"]
    builds = drawn or [mark for mark in marks if mark["name"] == "sidebar state"]

    def since_launch(mark: dict) -> float:
        return (mark["at"] - launched) * 1000

    def rows(mark: dict) -> int:
        return int(mark["detail"].get("sessions", "0"))

    first = next((mark for mark in builds if rows(mark) > 0), None)
    # The whole list: the first build after the last sidebar read landed.
    after_reads = (mark for mark in builds if since_launch(mark) >= last_read_ms)
    full = next(after_reads, builds[-1] if builds else None)
    for label, mark in (("first rows", first), ("full list", full)):
        if mark is None:
            print(f"{label}: never")
            continue
        # The core's marks are on its own thread; the others are the main thread's.
        until = [
            other for other in marks if other["at"] <= mark["at"] and other["name"] != "core event"
        ]
        spent = sum(other["ms"] for other in until)
        print(
            f"{label}: {since_launch(mark):.0f} ms, {rows(mark)} rows, "
            f"{mark['detail'].get('foldered', '?')} in folders; main thread "
            f"{mark['detail'].get('cpu', '?')} ms CPU since launch, {spent:.0f} ms in "
            f"{len(until)} list events and sidebar builds"
        )
    # A saved list's swap for the server's: the reset applied once the last read landed, which
    # draws nothing new when the rows are the same.
    swap = next(
        (
            mark
            for mark in marks
            if mark["name"] == "list event"
            and mark["message"].startswith("reset")
            # Within a few seconds of the reads, not a later reload's.
            and last_read_ms <= since_launch(mark) <= last_read_ms + 5_000
        ),
        None,
    )
    if swap is not None:
        print(f"server's list applied: {since_launch(swap):.0f} ms")
    counts = collections.Counter(mark["name"] for mark in marks)
    print(
        f"sidebar builds: {counts['sidebar state']}, list events applied: "
        f"{counts['list event']}, sent by the core: {counts['core event']}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    serve_parser = commands.add_parser("serve", help="run the proxy")
    serve_parser.add_argument("--listen", type=int, required=True)
    serve_parser.add_argument("--upstream", type=int, required=True)
    serve_parser.add_argument("--rtt-ms", type=float, default=150)
    serve_parser.add_argument("--mbps", type=float, default=0, help="bandwidth each way")
    serve_parser.add_argument("--log", help="the JSON-lines request log")
    report_parser = commands.add_parser("report", help="print a request log as a timeline")
    report_parser.add_argument("log")
    report_parser.add_argument(
        "--since-path", default="/.well-known/omnigent.json", help="time zero: its first request"
    )
    report_parser.add_argument(
        "--launched", type=float, help="time zero instead: the app's launch, in epoch seconds"
    )
    report_parser.add_argument(
        "--signposts", help="the app's sidebar signposts (log stream --style ndjson) to merge"
    )
    args = parser.parse_args()
    if args.command == "serve":
        serve(args)
    else:
        report(args)


if __name__ == "__main__":
    sys.exit(main())
