"""latency-proxy.py delays each exchange by the round trip and logs it as the app saw it."""

import asyncio
import http.client
import http.server
import importlib.util
import json
import sys
import tempfile
import threading
import time
import unittest
from argparse import Namespace
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "latency_proxy", Path(__file__).with_name("latency-proxy.py")
)
proxy_module = importlib.util.module_from_spec(spec)
sys.modules["latency_proxy"] = proxy_module
spec.loader.exec_module(proxy_module)


class ParserTests(unittest.TestCase):
    def messages(self, chunks: list[bytes]) -> list[tuple[str, int]]:
        ended = []
        heads = []
        parser = proxy_module.HttpParser(
            lambda line, _headers: heads.append(line) or "body",
            lambda message: ended.append((message.start_line, message.body_bytes)),
        )
        for chunk in chunks:
            parser.feed(chunk)
        return ended

    def test_lengths_and_chunks_end_each_message_across_reads(self):
        stream = (
            b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            b"3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"
            b"HTTP/1.1 204 No Content\r\n\r\n"
        )
        # One byte at a time, so every state waits for more.
        ended = self.messages([stream[index : index + 1] for index in range(len(stream))])
        self.assertEqual(
            ended,
            [("HTTP/1.1 200 OK", 5), ("HTTP/1.1 200 OK", 5), ("HTTP/1.1 204 No Content", 0)],
        )

    def test_report_names_hide_ids_and_keep_the_list_scope(self):
        self.assertEqual(
            proxy_module.kind("/v1/sessions/0123456789abcdef0123456789abcdef?include_items=false"),
            "/v1/sessions/{id}",
        )
        self.assertEqual(
            proxy_module.kind("/v1/sessions?limit=50&visibility=all&after=x&sort_by=updated_at"),
            "/v1/sessions?limit=50&visibility=all&after",
        )


class Echo(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        body = json.dumps({"path": self.path}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class ProxyTests(unittest.TestCase):
    def test_each_exchange_costs_a_round_trip_and_is_logged(self):
        upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Echo)
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        self.addCleanup(upstream.shutdown)
        log = Path(tempfile.mkdtemp()) / "proxy.jsonl"
        loop = asyncio.new_event_loop()
        log_file = log.open("a", encoding="utf-8")
        self.addCleanup(log_file.close)
        proxy = proxy_module.Proxy(
            Namespace(upstream=upstream.server_address[1], rtt_ms=200, mbps=0), log_file
        )
        server = loop.run_until_complete(asyncio.start_server(proxy.handle, "127.0.0.1", 0))
        port = server.sockets[0].getsockname()[1]
        threading.Thread(target=loop.run_forever, daemon=True).start()

        def stop() -> None:
            # The closed connection's pumps finish half a round trip later.
            async def idle() -> None:
                while len(asyncio.all_tasks()) > 1:
                    await asyncio.sleep(0.05)

            asyncio.run_coroutine_threadsafe(asyncio.wait_for(idle(), 5), loop).result()
            server.close()
            loop.call_soon_threadsafe(loop.stop)

        self.addCleanup(stop)

        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        times = []
        for path in ("/v1/info", "/v1/sessions?limit=3"):
            began = time.monotonic()
            connection.request("GET", path)
            self.assertEqual(json.loads(connection.getresponse().read())["path"], path)
            times.append(time.monotonic() - began)
        connection.close()

        # The first exchange pays the handshake too.
        self.assertGreaterEqual(times[0], 0.38)
        self.assertGreaterEqual(times[1], 0.19)
        self.assertLess(times[1], 0.38)
        rows = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual([row["target"] for row in rows], ["/v1/info", "/v1/sessions?limit=3"])
        self.assertTrue(all(row["status"] == 200 for row in rows))
        self.assertGreaterEqual(rows[1]["answered_ms"] - rows[1]["requested_ms"], 190)


if __name__ == "__main__":
    unittest.main()
