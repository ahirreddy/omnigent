#!/usr/bin/env python3
"""End-to-end test of protocol v1.1 on omnigent-browser-host (design doc section 16).

Starts the host on tests/pages/v11.html and checks: the hello's features; scroll and selection
reports go only to connections that asked; a control-scoped mobile resize (the page sees the
new size, touch support and, for `site`, a mobile user agent) and its restore on release, on a
take by another connection, and its adoption after the holder left; a repeated resize is a
no-op; touch events reach the page; edit copy, cut, paste and select all round-trip without
the OS clipboard.

    v11_test.py --host BIN [--encoder PATH] [--headless-mode ozone|xvfb] [--out DIR]
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from m0_bench import Host
from rb_client import AttachClient, AttachState

PAGE = Path(__file__).resolve().parent.parent / "tests" / "pages" / "v11.html"
FEATURES = ["viewport_scope", "mobile_emulation", "edit", "selection", "scroll_metrics", "touch"]
MOBILE = {"type": "resize", "w": 390, "h": 664, "dpr": 3, "scope": "control", "mobile": "layout"}


class Failure(AssertionError):
    """A failed check."""


def check(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)
    print(f"  ok: {message}")


def title(state: AttachState) -> str:
    return (state.last("nav") or {}).get("title", "")


def title_has(*parts: str):
    return lambda state: all(part in title(state).split(" ") for part in parts)


def holder(value: str | None):
    return lambda state: (
        (state.last("control") or {}).get("holder") == value
        and (state.last("control") or {}).get("owner")
        == ("user" if value is not None else "agent")
    )


def viewport(w: int, scope: str | None = None):
    def predicate(state: AttachState) -> bool:
        message = state.last("viewport") or {}
        return message.get("w") == w and message.get("scope") == scope

    return predicate


def count(state: AttachState, message_type: str) -> int:
    return sum(1 for message in state.messages if message.get("type") == message_type)


def take(viewer: AttachClient) -> None:
    viewer.send({"type": "control", "op": "take"})
    viewer.wait_for(holder("this"), 5, "take")


def edit(viewer: AttachClient, op: str, text: str | None = None) -> None:
    message = {"type": "edit", "op": op}
    if text is not None:
        message["text"] = text
    viewer.send(message)


def drag_scroll_bar(viewer: AttachClient) -> None:
    """Drags the page's scroll bar thumb 400 px, as the iOS client does: a 1 px scroll first
    shows overlay scroll bars (macOS hosts), then a left-button drag at the right edge."""

    def mouse(kind: str, y: float, **fields: object) -> None:
        viewer.send({"type": "mouse", "kind": kind, "x": 1272, "y": y, **fields})

    viewer.wheel(1272, 30, 1)
    viewer.pump(0.1)
    mouse("move", 30, modifiers=0)
    mouse("down", 30, button="left", clicks=1, modifiers=64)
    for y in range(30, 431, 40):
        mouse("move", y, modifiers=64)
        viewer.pump(0.03)
    mouse("up", 430, button="left", clicks=1, modifiers=0)
    viewer.wait_for(
        lambda s: (s.last("scroll") or {}).get("y", 0) > 2000, 5, "the scroll bar drag"
    )
    check(
        True, f"dragging the thumb 400 px scrolled to {(viewer.state.last('scroll') or {})['y']}"
    )
    while (viewer.state.last("scroll") or {}).get("y", 0) > 0:
        viewer.wheel(640, 400, -5000)
        viewer.pump(0.3)


def run(host: Host) -> None:
    tab = host.control.request(
        "tabs.create", {"session_id": "v11", "url": PAGE.as_uri(), "created_by": "user"}
    )
    holder_conn = AttachClient(str(host.socket), tab["id"], mode="control", features=FEATURES)
    plain = AttachClient(str(host.socket), tab["id"], mode="view")
    holder_conn.wait_for(title_has("w=1280"), 20, "the page")
    hello = holder_conn.state.last("hello") or {}
    check(set(FEATURES) <= set(hello.get("features", [])), f"hello features {hello['features']}")

    print("scroll reports")
    holder_conn.wait_for(
        lambda s: (s.last("scroll") or {}).get("content_h", 0) > 5000, 5, "the loaded page's size"
    )
    first = holder_conn.state.last("scroll") or {}
    # Classic scroll bars (Linux) take about 15 px of the layout viewport; overlay bars none.
    check(first["y"] == 0 and 1260 <= first["viewport_w"] <= 1280, f"scroll report {first}")
    take(holder_conn)
    started = time.monotonic()
    holder_conn.wheel(640, 400, 500)
    holder_conn.wait_for(lambda s: (s.last("scroll") or {}).get("y") == 500, 5, "scroll to 500")
    print(f"  wheel to scroll report: {(time.monotonic() - started) * 1000:.0f} ms")
    holder_conn.wheel(640, 400, -500)
    holder_conn.wait_for(lambda s: (s.last("scroll") or {}).get("y") == 0, 5, "scroll back")
    plain.pump(0.3)
    check(count(plain.state, "scroll") == 0, "a v1 connection gets no scroll reports")
    drag_scroll_bar(holder_conn)

    print("mobile size")
    holder_conn.send(MOBILE)
    holder_conn.wait_for(viewport(390, "control"), 5, "the control-scoped viewport")
    message = holder_conn.state.last("viewport") or {}
    check(
        message.get("mobile") == "layout" and message.get("agent", {}).get("w") == 1280,
        f"viewport message {message}",
    )
    holder_conn.wait_for(title_has("w=390", "touch=5", "dpr=3", "mobile=false"), 10, "390 px")
    check(True, f"page sees {title(holder_conn.state)}")
    holder_conn.wait_for(
        lambda s: (s.last("scroll") or {}).get("viewport_w") == 390, 5, "scroll report at 390"
    )
    holder_conn.wheel(200, 300, 600)
    holder_conn.wait_for(title_has("sy=600"), 5, "the page scrolled 600 CSS px")
    holder_conn.wait_for(
        lambda s: (s.last("scroll") or {}).get("y") == 600, 5, "a CSS px report at DPR 3"
    )
    check(True, "scroll reports are CSS px at DPR 3")
    holder_conn.wheel(200, 300, -600)
    holder_conn.wait_for(title_has("sy=0"), 5, "back at the top")
    plain.wait_for(lambda s: (s.last("viewport") or {}).get("w") == 390, 5, "viewer sees 390")
    holder_conn.pump(1.5)  # The resize's own IDR may still be on its way.
    viewports = count(holder_conn.state, "viewport")
    keyframes = sum(1 for frame in holder_conn.state.frames if frame.keyframe)
    holder_conn.send(MOBILE)
    holder_conn.pump(0.5)
    check(count(holder_conn.state, "viewport") == viewports, "a repeated resize sends nothing")
    check(
        sum(1 for frame in holder_conn.state.frames if frame.keyframe) == keyframes,
        "a repeated resize sends no IDR",
    )
    holder_conn.send({**MOBILE, "mobile": "site"})
    holder_conn.wait_for(title_has("mobile=true"), 10, "the mobile user agent")
    check(True, "mobile site sets a mobile user agent")

    print("touch")
    for kind, y in (("start", 300), ("move", 302), ("end", 302)):
        holder_conn.send(
            {"type": "touch", "kind": kind, "id": 7, "x": 100, "y": y, "modifiers": 0}
        )
    holder_conn.wait_for(title_has("touches=1"), 5, "a touchstart")
    check(True, "touch events reach the page")

    print("edit")
    holder_conn.click(100, 40)
    holder_conn.type_text("hello world")
    holder_conn.wait_for(
        title_has("value=hello", "world"), 5, "typing: " + title(holder_conn.state)
    )
    edit(holder_conn, "select_all")
    holder_conn.wait_for(
        lambda s: (s.last("selection") or {}).get("length") == 11, 5, "the selection report"
    )
    selection = holder_conn.state.last("selection") or {}
    check(
        selection["editable"] and not selection["collapsed"] and "rect" in selection,
        f"selection {selection}",
    )
    edit(holder_conn, "copy")
    holder_conn.wait_for(lambda s: s.last("clipboard") is not None, 5, "the copied text")
    clip = holder_conn.state.last("clipboard") or {}
    check(clip == {"type": "clipboard", "op": "copy", "text": "hello world"}, f"copy {clip}")
    edit(holder_conn, "paste", "pasted 世\U0001f30d")
    holder_conn.wait_for(title_has("pasted=1", "value=pasted"), 5, "the paste")
    check("世\U0001f30d" in title(holder_conn.state), f"paste {title(holder_conn.state)}")
    edit(holder_conn, "select_all")
    edit(holder_conn, "cut")
    holder_conn.wait_for(
        lambda s: (s.last("clipboard") or {}).get("op") == "cut", 5, "the cut text"
    )
    check(
        (holder_conn.state.last("clipboard") or {}).get("text") == "pasted 世\U0001f30d",
        "cut returns the text",
    )
    holder_conn.wait_for(lambda s: title(s).endswith("value="), 5, "the field emptied by cut")
    edit(holder_conn, "undo")
    holder_conn.wait_for(title_has("value=pasted"), 5, "undo restores the cut")
    check(True, "undo restores the cut text")
    plain.pump(0.2)
    check(count(plain.state, "clipboard") == 0, "only the requester gets the clipboard")
    check(count(plain.state, "selection") == 0, "a v1 connection gets no selection reports")

    print("ownership")
    holder_conn.send({"type": "control", "op": "release"})
    holder_conn.wait_for(viewport(1280, None), 5, "hand-back restores the agent's viewport")
    holder_conn.wait_for(title_has("w=1280", "touch=0", "mobile=false"), 10, "desktop again")
    check(True, "hand-back restores 1280 px, no touch, desktop user agent")

    take(holder_conn)
    holder_conn.send(MOBILE)
    holder_conn.wait_for(viewport(390, "control"), 5, "mobile again")
    other = AttachClient(str(host.socket), tab["id"], mode="control", features=FEATURES)
    other.wait_for(lambda s: (s.last("viewport") or {}).get("w") == 390, 10, "setup")
    take(other)
    other.wait_for(viewport(1280, None), 5, "a take by another connection restores")
    check(True, "a take by another connection restores the agent's viewport")

    other.send(MOBILE)
    other.wait_for(viewport(390, "control"), 5, "the other's mobile size")
    other.close()
    holder_conn.wait_for(
        lambda s: (s.last("control") or {}).get("reason") == "holder_left", 5, "holder_left"
    )
    take(holder_conn)
    holder_conn.pump(0.5)
    check(
        (holder_conn.state.last("viewport") or {}).get("w") == 390,
        "a take during the grace period adopts the orphaned viewport",
    )
    holder_conn.send(
        {"type": "resize", "w": 1280, "h": 800, "dpr": 1, "scope": "control", "mobile": "off"}
    )
    holder_conn.wait_for(viewport(1280, None), 5, "a resize to the agent's size restores")
    check(True, "a control resize equal to the agent's viewport restores it")

    holder_conn.close()
    plain.close()
    host.control.request("tabs.close", {"tab_id": tab["id"]})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--host", required=True)
    parser.add_argument("--encoder")
    parser.add_argument("--headless-mode", choices=["ozone", "xvfb"])
    parser.add_argument("--out", help="work directory (default: a temporary one, removed after)")
    args = parser.parse_args()
    out = Path(args.out) if args.out else Path(tempfile.mkdtemp(prefix="rb-v11-"))
    out.mkdir(parents=True, exist_ok=True)
    host = Host(args, out, None)
    try:
        run(host)
    except Failure as failure:
        print(f"FAIL: {failure}")
        return 1
    finally:
        host.stop()
        if not args.out:
            shutil.rmtree(out)
    print("v1.1 host test passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
