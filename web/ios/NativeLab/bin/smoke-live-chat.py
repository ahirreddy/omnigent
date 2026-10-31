#!/usr/bin/env python3
"""Opt-in real model round-trip through the isolated local API and SSE stream."""

import argparse
import asyncio
import json
from pathlib import Path
from time import monotonic, time
from urllib.parse import urlparse
from uuid import uuid4

import httpx

MIN_GROWTH_SECONDS = 0.25


def validate_incremental_reply(
    deltas: list[tuple[float, str]],
    final_text: str,
    begin: str,
    end: str,
    sent_at: float,
) -> None:
    """Check only chunks contributing to this probe's marked reply before completion."""
    final_text = final_text.strip()
    streamed = "".join(delta for _, delta in deltas)
    start = streamed.find(begin)
    end_start = streamed.find(end, start) if start >= 0 else -1
    stop = end_start + len(end) if end_start >= 0 else len(streamed)
    chunks: list[tuple[float, str]] = []
    offset = 0
    for received_at, delta in deltas:
        next_offset = offset + len(delta)
        if start >= 0 and offset < stop and next_offset > start:
            part = delta[max(0, start - offset) : min(len(delta), stop - offset)]
            if part:
                chunks.append((received_at, part))
        offset = next_offset

    first_delay = f"{chunks[0][0] - sent_at:.3f}s" if chunks else "n/a"
    growth = chunks[-1][0] - chunks[0][0] if chunks else 0.0
    first_chars = len(chunks[0][1]) if chunks else 0
    print(
        f"Incremental metrics: observed_nonempty_chunks={len(deltas)}, "
        f"reply_chunks_before_completion={len(chunks)}, time_to_first={first_delay}, "
        f"growth_window={growth:.3f}s, first_partial_chars={first_chars}, "
        f"final_chars={len(final_text)}",
        flush=True,
    )
    failures = []
    if not (final_text.startswith(begin) and final_text.endswith(end)):
        failures.append("completed reply is missing the requested begin/end boundaries")
    if "".join(part for _, part in chunks) != final_text:
        failures.append("pre-completion deltas did not reconstruct the completed marked reply")
    if len(chunks) < 2:
        failures.append("need at least 2 nonempty reply chunks before the completed item")
    if growth < MIN_GROWTH_SECONDS:
        failures.append(f"reply growth must span at least {MIN_GROWTH_SECONDS:.2f}s")
    if chunks and first_chars >= len(final_text):
        failures.append("the first partial already contained the full final response")
    if failures:
        raise RuntimeError(
            "FAIL: incremental streaming not verified; provider/gateway buffering may be present: "
            + "; ".join(failures)
        )
    print("PASS: incremental response growth verified before the completed assistant item.")


API = "http://127.0.0.1:6767"
WORKSPACE = Path(__file__).resolve().parents[4] / ".native-lab-server" / "chat-workspace"
TITLE_PREFIX = "Native streaming validation "


def probe_prompt(probe_id: str) -> tuple[str, str, str]:
    begin, end = f"NATIVE_STREAM_BEGIN_{probe_id}", f"NATIVE_STREAM_END_{probe_id}"
    prompt = (
        f"Begin your reply with {begin} on its own line. "
        "Then write 60 plain prose sentences, each at least 20 words long, about a peaceful "
        "imaginary garden through the seasons (about 8000 characters total). "
        f"End with {end} on its own line. No markdown, numbering, preface or afterword. "
        "Answer directly in chat. Do not call tools, run commands, or access files."
    )
    return prompt, begin, end


def item_text(item: dict) -> str:
    content = item.get("content", [])
    return content if isinstance(content, str) else "".join(p.get("text", "") for p in content)


def write_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


class StreamTrace:
    """Keep wire receipt times and per-message chunks, including on a failed probe."""

    def __init__(self, begin: str, end: str):
        self.begin, self.end = begin, end
        self.events: list[dict] = []
        self.groups: dict[str, list[tuple[float, str]]] = {}
        self.indices: dict[str, int] = {}
        self.final_text: str | None = None
        self.completed_at: float | None = None
        self.completed_epoch: float | None = None
        self.final_id: str | None = None
        self.prompt_at: float | None = None
        self.prompt_epoch: float | None = None

    def accept(self, event: dict, received: float, epoch: float) -> None:
        kind = event.get("type", "")
        row = {"type": kind, "monotonic": received, "epoch": epoch}
        # Do not persist arbitrary error payloads, credentials, or session snapshots.
        for field in ("message_id", "item_id", "index", "response_id", "status", "final"):
            if field in event:
                row[field] = event[field]
        if kind == "response.output_text.delta":
            delta = event.get("delta")
            if not isinstance(delta, str) or not delta:
                return
            row["delta"] = delta
            identity = event.get("message_id") or event.get("item_id") or event.get("response_id")
            key = str(identity or "unidentified")
            index = event.get("index")
            duplicate = isinstance(index, int) and index <= self.indices.get(key, -1)
            row["duplicate"] = duplicate
            if not duplicate and self.completed_at is None:
                self.groups.setdefault(key, []).append((received, delta))
                if isinstance(index, int):
                    self.indices[key] = index
        elif kind == "response.output_item.done":
            item = event.get("item") or {}
            text = item_text(item)
            row.update(item_id=item.get("id"), role=item.get("role"), chars=len(text))
            if item.get("role") == "user" and self.begin in text and self.prompt_at is None:
                self.prompt_at, self.prompt_epoch = received, epoch
            if item.get("role") == "assistant" and self.begin in text and self.final_text is None:
                self.final_text = text
                self.completed_at, self.completed_epoch = received, epoch
                self.final_id = item.get("id")
                row["text"] = text
        self.events.append(row)

    def reply_chunks(self) -> list[tuple[float, str]]:
        matches = [v for v in self.groups.values() if self.begin in "".join(s for _, s in v)]
        if len(matches) > 1:
            raise RuntimeError("Probe marker appeared in more than one streamed message.")
        return matches[0] if matches else []


def validate_visible_growth(samples: list[dict], final_text: str, completed_epoch: float) -> None:
    """Require two painted, screenshot-backed strict prefixes before wire completion."""

    def normalize(text: str) -> str:
        return " ".join(text.split())

    final = normalize(final_text)
    eligible = [
        s
        for s in samples
        if s.get("visible")
        and s.get("screenshot")
        and s["capture_finished_epoch"] < completed_epoch
        and 0 < len(normalize(s["text"])) < len(final)
        and final.startswith(normalize(s["text"]))
    ]
    for first in eligible:
        for later in eligible:
            if (
                later["epoch"] - first["epoch"] >= MIN_GROWTH_SECONDS
                and len(normalize(later["text"])) > len(normalize(first["text"]))
                and normalize(later["text"]).startswith(normalize(first["text"]))
            ):
                return
    raise RuntimeError(
        "Visible progressive growth not verified: need two screenshot-backed "
        "strict prefixes spanning 0.25s before the completed assistant item."
    )


async def get_json(client: httpx.AsyncClient, path: str) -> dict:
    response = await client.get(path)
    response.raise_for_status()
    return response.json()


async def verify_local(client: httpx.AsyncClient) -> None:
    info = await get_json(client, "/v1/info")
    identity = await get_json(client, "/v1/me")
    if (
        info.get("single_user") is not True
        or info.get("accounts_enabled") is not False
        or identity.get("user_id") != "local"
    ):
        raise RuntimeError("Expected the isolated single-user loopback API.")
    if not WORKSPACE.is_dir() or WORKSPACE.resolve() != WORKSPACE:
        raise RuntimeError("The dedicated chat workspace must exist and must not be a symlink.")


async def create_session(client: httpx.AsyncClient, probe_id: str) -> str:
    hosts = [
        h
        for h in (await get_json(client, "/v1/hosts"))["hosts"]
        if h.get("status") == "online"
        and h.get("configured_harnesses", {}).get("codex-native") is True
    ]
    if len(hosts) != 1:
        raise RuntimeError("Expected exactly one online host with configured codex-native.")
    host = hosts[0]
    agents = (await get_json(client, "/v1/agents?limit=1000"))["data"]
    agent = next(a for a in agents if a.get("name") == "codex-native-ui")
    body = {
        "agent_id": agent["id"],
        "host_id": host["host_id"],
        "workspace": str(WORKSPACE),
        "title": TITLE_PREFIX + probe_id,
    }
    response = await client.post("/v1/sessions", json=body)
    response.raise_for_status()
    return response.json()["id"]


async def select_session_model(client: httpx.AsyncClient, session_id: str, model: str) -> None:
    # Codex publishes its catalog after launch; host model previews are Claude-only.
    deadline = monotonic() + 60
    while True:
        snapshot = await verified_session(client, session_id)
        options = snapshot.get("model_options") or []
        if options:
            break
        if monotonic() >= deadline:
            raise RuntimeError("The disposable runner did not publish a model catalog within 60s.")
        await asyncio.sleep(0.5)
    if not any(model in (m.get("id"), m.get("model")) and not m.get("hidden") for m in options):
        raise RuntimeError(
            "Requested model is absent from the runner's current supported catalog."
        )
    response = await client.patch(f"/v1/sessions/{session_id}", json={"model_override": model})
    response.raise_for_status()


async def verified_session(client: httpx.AsyncClient, session_id: str) -> dict:
    snapshot = await get_json(client, f"/v1/sessions/{session_id}?include_items=false")
    title = snapshot.get("title") or ""
    if (title != "Native live chat" and not title.startswith(TITLE_PREFIX)) or snapshot.get(
        "workspace"
    ) != str(WORKSPACE):
        raise RuntimeError("Refusing to send outside a dedicated local streaming test session.")
    if not snapshot.get("host_online") or snapshot.get("status") not in ("idle", "failed"):
        raise RuntimeError("The dedicated session must have an online host and no active turn.")
    return {
        key: snapshot.get(key)
        for key in (
            "id",
            "title",
            "workspace",
            "host_id",
            "harness",
            "llm_model",
            "model_override",
            "runner_online",
            "host_online",
            "status",
            "model_options",
        )
    }


async def observe_web(
    url: str,
    session_id: str,
    begin: str,
    evidence: Path,
    ready: asyncio.Event,
    finished: asyncio.Event,
    samples: list[dict],
) -> None:
    """Read the normal web UI; no response routing, store writes, or synthetic deltas."""
    from playwright.async_api import async_playwright

    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch()
        page = None
        try:
            page = await browser.new_page(viewport={"width": 1280, "height": 1000})
            stream_seen = asyncio.Event()
            page.on(
                "response",
                lambda response: (
                    stream_seen.set()
                    if f"/v1/sessions/{session_id}/stream" in response.url
                    and response.status == 200
                    else None
                ),
            )
            await page.goto(f"{url.rstrip('/')}/c/{session_id}", wait_until="domcontentloaded")
            await asyncio.wait_for(stream_seen.wait(), 40)
            # Reading after two animation frames gives the browser a paint opportunity.
            ready.set()
            last = ""
            while not finished.is_set():
                sample = await page.evaluate(
                    """async (begin) => {
                  await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
                  const selector = '[data-testid="assistant-text-section"]';
                  const nodes = [...document.querySelectorAll(selector)];
                  const node = nodes.find(n => n.innerText.startsWith(begin));
                  if (!node) return null;
                  const rect = node.getBoundingClientRect();
                  return {text: node.innerText, epoch: Date.now()/1000,
                    visible: rect.bottom > 0 && rect.top < innerHeight && rect.width > 0};
                }""",
                    begin,
                )
                if sample and sample["text"] != last:
                    last = sample["text"]
                    name = f"web-{len(samples):03d}.png"
                    sample["screenshot"] = name
                    sample["capture_started_epoch"] = time()
                    await page.screenshot(path=str(evidence / name))
                    sample["capture_finished_epoch"] = time()
                    samples.append(sample)
                    write_json(evidence / "web-samples.json", samples)
                await asyncio.sleep(0.1)
            await page.screenshot(path=str(evidence / "web-final.png"))
        except Exception as error:
            write_json(evidence / "web-error.json", {"failure_type": type(error).__name__})
            if page is not None:
                await page.screenshot(path=str(evidence / "web-error.png"), timeout=5000)
            raise
        finally:
            await browser.close()


async def run(args: argparse.Namespace) -> None:
    prompt, begin, end = probe_prompt(args.probe_id)
    if not args.require_incremental:
        begin = "Omni native live connection works."
        end = begin
        prompt = f"Reply with exactly: {begin} Do not call tools or access files."
    trace = StreamTrace(begin, end)
    ready, web_ready, finished = asyncio.Event(), asyncio.Event(), asyncio.Event()
    web_samples: list[dict] = []
    evidence = args.evidence_dir
    if evidence:
        evidence.mkdir(parents=True, exist_ok=True)
        if (evidence / "result.json").exists() or (evidence / "ready.json").exists():
            raise RuntimeError(
                "Use a fresh evidence directory; refusing to overwrite a prior probe."
            )
    result: dict = {
        "probe_id": args.probe_id,
        "source": "configured-live-provider",
        "prompt_sent": False,
        "generated_reply_received": False,
        "passed": False,
        "mode": "prepare-only"
        if args.prepare_only
        else ("observe-native-send" if args.observe_only else "api-send"),
        "started_epoch": time(),
        "api": API,
    }
    watcher = web_task = None
    try:
        async with httpx.AsyncClient(
            base_url=API,
            timeout=httpx.Timeout(60, read=300),
            trust_env=False,
            follow_redirects=False,
        ) as client:
            await verify_local(client)
            session_id = args.session_id
            if args.create_session:
                session_id = await create_session(client, args.probe_id)
            result["session_id"] = session_id
            if args.model:
                await select_session_model(client, session_id, args.model)
            snapshot = await verified_session(client, session_id)
            result["session"] = snapshot
            if args.model and snapshot.get("model_override") != args.model:
                raise RuntimeError("Session did not acknowledge the requested model override.")
            plan = {
                "session_id": session_id,
                "probe_id": args.probe_id,
                "prompt": prompt,
                "begin": begin,
                "end": end,
                "session": snapshot,
            }
            if evidence:
                write_json(evidence / "plan.json", plan)
            print(
                f"Dedicated session: {session_id}; model: "
                f"{snapshot.get('model_override') or snapshot.get('llm_model')}",
                flush=True,
            )
            if args.prepare_only:
                print("Prepared only; no prompt sent.", flush=True)
                result["prepared"] = True
                return

            async def watch() -> str:
                async with client.stream("GET", f"/v1/sessions/{session_id}/stream") as stream:
                    stream.raise_for_status()
                    async for line in stream.aiter_lines():
                        if not line.startswith("data: ") or line == "data: [DONE]":
                            continue
                        event = json.loads(line[6:])
                        trace.accept(event, monotonic(), time())
                        if evidence:
                            write_json(evidence / "wire.json", trace.events)
                        if event.get("type") == "session.heartbeat":
                            ready.set()
                        if event.get("type") == "response.failed" or (
                            event.get("type") == "session.status"
                            and event.get("status") == "failed"
                        ):
                            raise RuntimeError(
                                "The local runner reported a failed turn (payload omitted)."
                            )
                        if trace.final_text is not None:
                            return trace.final_text
                    raise RuntimeError("Stream ended before a completed marked assistant reply.")

            watcher = asyncio.create_task(watch())
            readiness = asyncio.create_task(ready.wait())
            done, _ = await asyncio.wait(
                [watcher, readiness], timeout=20, return_when=asyncio.FIRST_COMPLETED
            )
            readiness.cancel()
            if watcher in done:
                await watcher
            if not ready.is_set():
                raise RuntimeError("No SSE readiness heartbeat within 20 seconds.")
            if args.web_url:
                web_task = asyncio.create_task(
                    observe_web(
                        args.web_url, session_id, begin, evidence, web_ready, finished, web_samples
                    )
                )
                wait_web = asyncio.create_task(web_ready.wait())
                done, _ = await asyncio.wait(
                    [web_task, wait_web], timeout=50, return_when=asyncio.FIRST_COMPLETED
                )
                wait_web.cancel()
                if web_task in done:
                    await web_task
                if not web_ready.is_set():
                    raise RuntimeError("Normal web UI did not connect its session SSE stream.")
            sent_at = monotonic()
            if evidence:
                write_json(evidence / "ready.json", {**plan, "ready_epoch": time()})
            if not args.observe_only:
                response = await client.post(
                    f"/v1/sessions/{session_id}/events",
                    json={
                        "type": "message",
                        "data": {
                            "role": "user",
                            "content": [{"type": "input_text", "text": prompt}],
                        },
                    },
                )
                response.raise_for_status()
                if response.json().get("denied"):
                    raise RuntimeError("Test prompt denied; no retry attempted.")
                result["prompt_sent"] = True
                print("Prompt accepted; waiting for real model output...", flush=True)
            else:
                print(
                    "READY: SSE and optional web observer connected; send via native UI now.",
                    flush=True,
                )
            final_text = await asyncio.wait_for(watcher, timeout=args.timeout)
            result["generated_reply_received"] = True
            # Allow normal final rendering; samples after completion cannot count as progressive.
            if web_task:
                await asyncio.sleep(1)
                finished.set()
                await asyncio.wait_for(web_task, 15)
            chunks = trace.reply_chunks()
            result.update(
                final_chars=len(final_text),
                reply_chunks=len(chunks),
                completed_epoch=trace.completed_epoch,
                final_item_id=trace.final_id,
                first_delta_epoch=next(
                    (
                        e["epoch"]
                        for e in trace.events
                        if e["type"] == "response.output_text.delta"
                    ),
                    None,
                ),
                growth_seconds=chunks[-1][0] - chunks[0][0] if chunks else 0,
                prompt_observed_epoch=trace.prompt_epoch,
            )
            # Re-read actual runner identity; creation acknowledgment alone is not support proof.
            actual = await get_json(client, f"/v1/sessions/{session_id}?include_items=false")
            result["actual_model"] = actual.get("llm_model")
            result["actual_harness"] = actual.get("harness")
            result["actual_model_options"] = [
                {key: model.get(key) for key in ("id", "model", "isDefault")}
                for model in actual.get("model_options", [])
            ]
            if args.model and args.model != actual.get("llm_model"):
                raise RuntimeError("Runner's actual model does not match the requested override.")
            if args.require_incremental:
                origin = trace.prompt_at if args.observe_only else sent_at
                if origin is None:
                    raise RuntimeError("The observer did not receive the marked user prompt.")
                validate_incremental_reply(chunks, final_text, begin, end, origin)
                if web_task:
                    validate_visible_growth(web_samples, final_text, trace.completed_epoch)
            elif not chunks:
                raise RuntimeError("Completed reply arrived without text deltas.")
            result["passed"] = True
            print(
                "PASS: real SSE probe" + (" and normal web visible growth." if web_task else ".")
            )
    except BaseException as error:
        # Exception bodies from network/provider code may contain sensitive details.
        result["failure_type"] = type(error).__name__
        if isinstance(error, (RuntimeError, TimeoutError)):
            result["failure"] = str(error)
        raise
    finally:
        finished.set()
        for task in (watcher, web_task):
            if task is not None and not task.done():
                task.cancel()
        await asyncio.gather(*(t for t in (watcher, web_task) if t), return_exceptions=True)
        if evidence:
            write_json(evidence / "wire.json", trace.events)
            write_json(evidence / "web-samples.json", web_samples)
            result["finished_epoch"] = time()
            write_json(evidence / "result.json", result)
            print(f"Evidence: {evidence}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session_id", nargs="?")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--send-test-prompt", action="store_true")
    mode.add_argument(
        "--observe-only", action="store_true", help="Native UI sends the marked prompt."
    )
    mode.add_argument(
        "--prepare-only", action="store_true", help="Create/verify session without a prompt."
    )
    parser.add_argument("--create-session", action="store_true")
    parser.add_argument(
        "--model", help="Supported catalog model; only on a newly created session."
    )
    parser.add_argument("--probe-id", default=uuid4().hex)
    parser.add_argument("--evidence-dir", type=Path)
    parser.add_argument(
        "--web-url", help="Normal loopback web UI; observe the same generated turn."
    )
    parser.add_argument("--timeout", type=float, default=240)
    parser.add_argument("--require-incremental", action="store_true")
    args = parser.parse_args()
    if bool(args.session_id) == args.create_session:
        parser.error("Supply a dedicated session ID or --create-session, exclusively.")
    if (args.session_id and not args.session_id.isalnum()) or not args.probe_id.isalnum():
        parser.error("Session and probe IDs must be alphanumeric.")
    if args.model and not args.create_session:
        parser.error("--model is permitted only with --create-session.")
    if (args.observe_only or args.prepare_only or args.web_url) and not args.evidence_dir:
        parser.error("This mode requires --evidence-dir.")
    if args.observe_only and not args.require_incremental:
        parser.error("--observe-only requires --require-incremental.")
    if args.web_url:
        parsed = urlparse(args.web_url)
        if (
            parsed.scheme != "http"
            or parsed.hostname not in ("127.0.0.1", "localhost")
            or parsed.username
            or parsed.password
            or parsed.query
            or parsed.fragment
        ):
            parser.error("--web-url must be an unauthenticated loopback HTTP origin.")
    try:
        asyncio.run(run(args))
    except (httpx.HTTPError, TimeoutError, RuntimeError) as error:
        message = (
            str(error) if isinstance(error, (RuntimeError, TimeoutError)) else type(error).__name__
        )
        raise SystemExit(f"Live streaming not verified; no retry attempted: {message}") from None


if __name__ == "__main__":
    main()
