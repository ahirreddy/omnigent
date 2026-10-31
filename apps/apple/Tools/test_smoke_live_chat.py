"""Offline regression checks for the opt-in streaming smoke validator."""

import importlib.util
import io
import json
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import httpx

spec = importlib.util.spec_from_file_location(
    "smoke_live_chat", Path(__file__).with_name("smoke-live-chat.py")
)
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class IncrementalReplyTests(unittest.TestCase):
    begin = "NATIVE_STREAM_BEGIN_test"
    end = "NATIVE_STREAM_END_test"
    reply = f"{begin}\n" + "A peaceful garden. " * 350 + f"\n{end}"

    def validate(self, deltas, final_text=None):
        output = io.StringIO()
        with redirect_stdout(output):
            smoke.validate_incremental_reply(
                deltas, self.reply if final_text is None else final_text, self.begin, self.end, 10
            )
        return output.getvalue()

    def test_progressive_reply_reports_timing_and_growth(self):
        output = self.validate([(11, self.reply[:100]), (11.25, self.reply[100:])])
        self.assertIn("PASS:", output)
        self.assertIn("reply_chunks_before_completion=2", output)
        self.assertIn("time_to_first=1.000s", output)
        self.assertIn("growth_window=0.250s", output)
        self.assertIn("first_partial_chars=100", output)

    def test_split_markers_and_unrelated_text_do_not_distort_metrics(self):
        output = self.validate(
            [
                (10.1, "older response"),
                (11, "unrelated prefix" + self.reply[:8]),
                (11.3, self.reply[8:-8]),
                (11.5, self.reply[-8:] + "unrelated suffix"),
                (30, "later unrelated response"),
            ]
        )
        self.assertIn("reply_chunks_before_completion=3", output)
        self.assertIn("time_to_first=1.000s", output)
        self.assertIn("growth_window=0.500s", output)

    def test_buffered_or_incomplete_replies_fail(self):
        cases = {
            "no pre-completion chunks": ([], "at least 2 nonempty"),
            "single full chunk": ([(38, self.reply)], "first partial already contained"),
            "rapid burst": (
                [(38, self.reply[:100]), (38.01, self.reply[100:])],
                "growth must span at least 0.25s",
            ),
            "just below threshold": (
                [(11, self.reply[:100]), (11.249, self.reply[100:])],
                "growth must span at least 0.25s",
            ),
            "full chunk plus empty or trailing chunks": (
                [(11, self.reply), (12, ""), (13, " \n"), (14, self.reply)],
                "first partial already contained",
            ),
            "unrelated text before buffered reply": (
                [(11, "old reply"), (12, self.reply)],
                "at least 2 nonempty",
            ),
            "missing last delta": (
                [(11, self.reply[:100]), (12, self.reply[100:-50])],
                "did not reconstruct",
            ),
            "different streamed text": (
                [(11, self.reply[:100]), (12, "changed" + self.reply[100:])],
                "did not reconstruct",
            ),
        }
        for name, (deltas, reason) in cases.items():
            with self.subTest(name=name):
                with self.assertRaisesRegex(RuntimeError, reason) as failure:
                    self.validate(deltas)
                self.assertIn("provider/gateway buffering", str(failure.exception))

    def test_missing_end_marker_fails_explicitly(self):
        incomplete = self.reply[: -len(self.end)]
        with self.assertRaisesRegex(RuntimeError, "missing the requested begin/end boundaries"):
            self.validate([(11, incomplete[:100]), (12, incomplete[100:])], incomplete)

    def test_failure_still_reports_metrics(self):
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaises(RuntimeError):
            smoke.validate_incremental_reply(
                [(38, self.reply)], self.reply, self.begin, self.end, 10
            )
        self.assertIn("reply_chunks_before_completion=1", output.getvalue())
        self.assertIn("time_to_first=28.000s", output.getvalue())
        self.assertIn("growth_window=0.000s", output.getvalue())


class WireTraceTests(unittest.TestCase):
    def setUp(self):
        self.trace = smoke.StreamTrace("BEGIN", "END")

    def delta(self, text, at, identity="model-message", index=None):
        event = {"type": "response.output_text.delta", "delta": text, "message_id": identity}
        if index is not None:
            event["index"] = index
        self.trace.accept(event, at, at + 1000)

    def complete(self, text="BEGIN garden END", at=13):
        self.trace.accept(
            {
                "type": "response.output_item.done",
                "item": {
                    "id": "committed",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": text}],
                },
            },
            at,
            at + 1000,
        )

    def test_wrapper_completion_does_not_end_native_message(self):
        self.trace.accept({"type": "response.completed"}, 10, 1010)
        self.delta("BE", 11, index=0)
        self.delta("GIN garden END", 12, index=1)
        self.complete()
        self.assertEqual(len(self.trace.reply_chunks()), 2)
        self.assertEqual(self.trace.completed_epoch, 1013)
        self.assertEqual(self.trace.final_id, "committed")

    def test_native_send_timing_starts_at_marked_user_item_not_observer_start(self):
        self.trace.accept({"type": "session.heartbeat"}, 1, 1001)
        self.trace.accept(
            {
                "type": "response.output_item.done",
                "item": {"role": "user", "content": "Reply from BEGIN to END"},
            },
            20,
            1020,
        )
        self.complete(at=25)
        self.assertEqual(self.trace.prompt_at, 20)
        self.assertEqual(self.trace.prompt_epoch, 1020)
        self.assertEqual(self.trace.completed_epoch, 1025)

    def test_replayed_index_and_post_completion_delta_cannot_count(self):
        self.delta("BEGIN garden END", 11, index=0)
        self.delta("BEGIN garden END", 12, index=0)
        self.complete()
        self.delta("late", 14, index=1)
        self.assertEqual(self.trace.reply_chunks(), [(11, "BEGIN garden END")])
        self.assertTrue(self.trace.events[1]["duplicate"])

    def test_different_message_ids_cannot_manufacture_growth(self):
        self.delta("BEGIN garden ", 11, "first")
        self.delta("END", 12, "second")
        self.complete()
        with self.assertRaisesRegex(RuntimeError, "did not reconstruct"):
            smoke.validate_incremental_reply(
                self.trace.reply_chunks(), self.trace.final_text, "BEGIN", "END", 10
            )

    def test_marker_in_two_messages_is_ambiguous(self):
        self.delta("BEGIN first END", 11, "first")
        self.delta("BEGIN second END", 12, "second")
        with self.assertRaisesRegex(RuntimeError, "more than one"):
            self.trace.reply_chunks()

    def test_error_and_snapshot_secrets_are_not_saved(self):
        secret = "never-store-this-secret"
        self.trace.accept({"type": "response.failed", "error": {"message": secret}}, 11, 1011)
        self.trace.accept({"type": "session.status", "authorization": secret}, 12, 1012)
        self.assertNotIn(secret, json.dumps(self.trace.events))


class VisibleGrowthTests(unittest.TestCase):
    final = "BEGIN a peaceful garden with roses END"

    def sample(self, text, epoch, **kwargs):
        return {
            "text": text,
            "epoch": epoch,
            "capture_finished_epoch": epoch + 0.1,
            "visible": True,
            "screenshot": "observed.png",
            **kwargs,
        }

    def test_two_visible_partial_screenshots_before_completion(self):
        smoke.validate_visible_growth(
            [self.sample("BEGIN a", 1), self.sample("BEGIN a peaceful garden", 2)], self.final, 3
        )

    def test_bulk_late_hidden_changed_and_missing_screenshots_fail(self):
        first = self.sample("BEGIN a", 1)
        cases = {
            "full first": [self.sample(self.final, 1), self.sample(self.final, 2)],
            "only one": [first],
            "capture after complete": [first, self.sample("BEGIN a peaceful", 2.95)],
            "post complete growth": [first, self.sample("BEGIN a peaceful", 4)],
            "not visible": [first, self.sample("BEGIN a peaceful", 2, visible=False)],
            "not a prefix": [first, self.sample("BEGIN unrelated content", 2)],
            "no screenshot": [first, self.sample("BEGIN a peaceful", 2, screenshot=None)],
            "burst": [first, self.sample("BEGIN a peaceful", 1.1)],
            "same text": [first, self.sample("BEGIN a", 2)],
        }
        for name, samples in cases.items():
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, "not verified"):
                smoke.validate_visible_growth(samples, self.final, 3)


class LocalBoundaryTests(unittest.IsolatedAsyncioTestCase):
    async def test_unsupported_model_never_updates_session_or_sends_prompt(self):
        requests = []

        def handle(request):
            requests.append(request)
            self.assertEqual(request.method, "GET")
            return httpx.Response(
                200,
                json={
                    "title": smoke.TITLE_PREFIX + "test",
                    "workspace": str(smoke.WORKSPACE),
                    "host_online": True,
                    "status": "idle",
                    "model_options": [{"id": "supported"}],
                },
            )

        async with httpx.AsyncClient(
            base_url=smoke.API, transport=httpx.MockTransport(handle)
        ) as c:
            with self.assertRaisesRegex(RuntimeError, "absent from"):
                await smoke.select_session_model(c, "disposable", "unsupported")
        self.assertEqual(len(requests), 1)

    async def test_session_override_only_on_verified_disposable_session(self):
        requests = []

        def handle(request):
            requests.append(request)
            self.assertEqual(request.url.path, "/v1/sessions/disposable")
            if request.method == "GET":
                data = {
                    "title": smoke.TITLE_PREFIX + "test",
                    "workspace": str(smoke.WORKSPACE),
                    "host_online": True,
                    "status": "idle",
                    "model_options": [{"id": "supported"}],
                }
            else:
                self.assertEqual(request.method, "PATCH")
                self.assertEqual(json.loads(request.content), {"model_override": "supported"})
                data = {"model_override": "supported"}
            return httpx.Response(200, json=data)

        async with httpx.AsyncClient(
            base_url=smoke.API, transport=httpx.MockTransport(handle)
        ) as c:
            await smoke.select_session_model(c, "disposable", "supported")
        self.assertEqual([r.method for r in requests], ["GET", "PATCH"])

    async def test_create_uses_configured_default_without_host_catalog_or_prompt(self):
        requests = []

        def handle(request):
            requests.append(request)
            if request.url.path == "/v1/hosts":
                data = {
                    "hosts": [
                        {
                            "host_id": "host",
                            "status": "online",
                            "configured_harnesses": {"codex-native": True},
                        }
                    ]
                }
            elif request.url.path == "/v1/agents":
                data = {"data": [{"name": "codex-native-ui", "id": "agent"}]}
            else:
                self.assertEqual(request.url.path, "/v1/sessions")
                self.assertEqual(request.method, "POST")
                body = json.loads(request.content)
                self.assertNotIn("model_override", body)
                self.assertEqual(body["title"], smoke.TITLE_PREFIX + "test")
                self.assertEqual(body["workspace"], str(smoke.WORKSPACE))
                data = {"id": "disposable"}
            return httpx.Response(200, json=data)

        async with httpx.AsyncClient(
            base_url=smoke.API, transport=httpx.MockTransport(handle)
        ) as c:
            self.assertEqual(await smoke.create_session(c, "test"), "disposable")
        self.assertEqual([r.url.path for r in requests if r.method != "GET"], ["/v1/sessions"])

    async def test_unrelated_or_active_session_is_refused(self):
        good = {
            "title": smoke.TITLE_PREFIX + "test",
            "workspace": str(smoke.WORKSPACE),
            "host_online": True,
            "status": "idle",
        }
        for changed in (
            {"title": "User work"},
            {"workspace": "/other"},
            {"status": "running"},
            {"host_online": False},
        ):
            with self.subTest(changed=changed):
                transport = httpx.MockTransport(
                    lambda _, changed=changed: httpx.Response(200, json=good | changed)
                )
                async with httpx.AsyncClient(base_url=smoke.API, transport=transport) as c:
                    with self.assertRaises(RuntimeError):
                        await smoke.verified_session(c, "test")


if __name__ == "__main__":
    unittest.main()
