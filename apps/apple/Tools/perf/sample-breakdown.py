#!/usr/bin/env python3
"""Where a `sample` report's main thread spent its on-CPU time, by what the work was and by the
step of the frame it ran in.

    sample-breakdown.py <report.sample.txt> [...] [--top 25] [--frames REGEX]

A sample goes to the first category (CATEGORIES, in order) with a rule that matches a frame of
its stack, so work a text overlay, a markdown parse or a scroll observer caused counts there
even where it ends in layout, and typesetting that drawing does counts as drawing; under each
category are the innermost frames its rule matched. Its step is the first of STEPS that matches.
Reports of several runs add up; waits are left out. `--frames REGEX` also lists the inclusive
samples of frames matching REGEX.
"""

from __future__ import annotations

import argparse
import re
from collections import Counter
from pathlib import Path

WAITS = ("mach_msg2_trap", "__psynch_cvwait", "__ulock_wait", "__semwait", "__select", "kevent")
LINE = re.compile(r"^([ +!:|]*)(\d+) (.+)")
# The app's own code: statically linked packages show as the app's binary.
APP = re.compile(r"\(in Omnigent\)")

# (category, rule), most specific first.
CATEGORIES: list[tuple[str, re.Pattern[str]]] = [
    # The table list (`-omnigent:transcript-list table`): rows measured before they show or
    # while idle, and the table asking for a row's cell.
    ("table: rows measured", re.compile(r"TranscriptTableController\.(measure|prefetch)")),
    (
        "table: cells filled and rows placed",
        re.compile(r"TranscriptTableController\.tableView|TranscriptTableCell\.show"),
    ),
    (
        "AppKit views per text (selection overlays, link areas)",
        re.compile(
            r"AppKitTextSelectionRepresentation|SelectionOverlay|NSTextInsertionIndicator"
            r"|TextSelectionRepresentation|_NSTextSelection|NSTextView|LinkPointerAreas"
            r"|PlatformViewRepresentableAdaptor|makeViewProvider|PlatformViewChild"
        ),
    ),
    (
        "markdown parse and attributed strings",
        re.compile(
            r"(MarkdownDocument|MarkdownCache|MarkdownRenderMemo|MarkdownStream|CodeHighlight"
            r"|TypeRamp\.sizing|LinkGeometry|MathSpan|MarkdownTableText|MarkdownParagraphText\.\w+\("
            r"|WorkspaceFileLinks\.linking|CLIStyledMarkdown\.\w+\(|CLISourceText\.\w+\(|cmark_"
            r"|Markdown\.\w+(Parser|Visitor|Document)).*\(in Omnigent\)"
        ),
    ),
    (
        "scroll-position observers and what they render",
        re.compile(
            r"TranscriptScrollState|ReadingAnchor|TranscriptReadingPosition|updateActiveTurn"
            r"|TurnRail|JumpToLatestPill|JumpToTopReveal|ScrollTopReveal|TranscriptFollow"
            r"|ScrollEdgeWatch|EndByEdge|HeldRowWidth|TranscriptRowWidth|LoopProbe|HangTrace"
            r"|ScrollGeometry|GeometryChange|ScrollTargetVisibility|VisibilityChange|ScrollPhase"
            r"|onScrollPhase|ScrollStateRequest|ContentOffset|TranscriptView\.body"
            # The new offset entering the graph, and what it marks to update.
            r"|ScrollViewCommitMutation"
        ),
    ),
    (
        "drawing layer contents (text drawn and typeset again)",
        re.compile(r"CA::Layer::display_if_needed|CABackingStoreUpdate|CGDrawingLayer|drawLayer"),
    ),
    (
        "text layout and typesetting",
        re.compile(
            r"\(in CoreText\)|\(in UIFoundation\)|ResolvedStyledText|StyledTextLayout|TextLayout"
            r"|NSStringDrawing|MetricsCache"
        ),
    ),
    (
        "rows materializing (views built, row bodies, prefetch)",
        re.compile(
            r"ScrollViewHelper\.prefetch|LazySubviewPrefetcher|prefetchOutputs|updateItems"
            r"|makeItemLayout|makeViewImpl|_makeView|makeElements|makeAllElements|makeViewList"
            r"|instantiate|AGSubgraphCreate|Subgraph::add_child|AGGraphCreate|add_attribute"
            r"|\.body\.getter.*\(in Omnigent\)|body\(content:\).*\(in Omnigent\)"
        ),
    ),
    (
        "lazy stack placement and height estimation",
        re.compile(
            r"LazySubviewPlacements|LazyStack|StackPlacement|LazyHVStack|LazyLayout|LazyViewGeometry"
            r"|ForEachState|ForEachList|applyNodes|applySublists|ViewList"
        ),
    ),
    (
        "display list, view and layer updates, commit",
        re.compile(
            r"DisplayList\.ViewUpdater|ViewGraph\.renderDisplayList|renderOnMainThread"
            r"|CA::Context::commit_transaction|RendererEffectDisplayList|InterpolatedDisplayList"
            r"|DisplayList\.Key|PreferenceCombiner|_buildLayerTree"
        ),
    ),
    (
        "AppKit tracking areas and cursor rects",
        re.compile(r"_NSTrackingArea|[Cc]ursorRect"),
    ),
    ("scroll event handling", re.compile(r"sendEvent|scrollWheel|NSScrollView|NSClipView")),
    (
        "other SwiftUI layout and graph",
        re.compile(r"^(?!.*(runApp|App\.main)).*\(in (SwiftUI|SwiftUICore|AttributeGraph)\)"),
    ),
    (
        "perf tooling (hitch monitor ping, frame logger)",
        re.compile(r"hitch-monitor|driver\.dylib|OmnigentFrameLogger|_dispatch_semaphore_signal"),
    ),
    (
        "AppKit view tree, constraints, display link and run loop",
        re.compile(
            r"\(in (AppKit|CoreAutoLayout|QuartzCore|CoreFoundation|UpdateCycle|SkyLight)\)"
        ),
    ),
]

# (step, rule): where in the frame the work ran; the first that matches a frame of the stack.
STEPS: list[tuple[str, re.Pattern[str]]] = [
    ("scroll event", re.compile(r"sendEvent|scrollWheel")),
    (
        "idle-time prefetch",
        re.compile(r"ScrollViewHelper\._updateCycleIdle|ScrollViewHelper\.prefetch"),
    ),
    ("draw layers", re.compile(r"CA::Layer::display_if_needed")),
    ("commit layers", re.compile(r"CA::Context::commit_transaction")),
    ("layout: display list to views", re.compile(r"renderDisplayList|DisplayList\.ViewUpdater")),
    ("layout: graph update", re.compile(r"GraphHost\.flushTransactions|ViewGraph\.updateOutputs")),
    ("tracking areas", re.compile(r"_NSTrackingAreaAKManager")),
    ("layout: other", re.compile(r"NSHostingView\.layout|layoutSubtreeIfNeeded|NSDisplayCycle")),
    ("display link", re.compile(r"DisplayLink")),
    ("main queue, tasks, timers", re.compile(r"main_queue|TIMER|swift_task|swift_job")),
]


def main_thread(text: str) -> list[tuple[int, int, str]]:
    """(depth, count, frame) rows of the main thread's call tree in a `sample` report."""
    lines = text.split("\n")
    start = next(
        index
        for index, line in enumerate(lines)
        if re.match(r"^    \d+ Thread_\d+.*Main Thread", line) or "com.apple.main-thread" in line
    )
    end = next(
        (i for i in range(start + 1, len(lines)) if re.match(r"^    \d+ Thread_", lines[i])),
        len(lines),
    )
    return [
        (len(m.group(1)), int(m.group(2)), m.group(3).strip())
        for m in map(LINE.match, lines[start:end])
        if m
    ]


def stacks(rows: list[tuple[int, int, str]]) -> Counter[tuple[str, ...]]:
    """Each distinct stack (outermost frame first) with the samples that end in it."""
    found: Counter[tuple[str, ...]] = Counter()
    path: list[str] = []
    depths: list[int] = []
    for index, (depth, count, name) in enumerate(rows):
        while depths and depths[-1] >= depth:
            depths.pop()
            path.pop()
        depths.append(depth)
        path.append(name)
        own = count - children_total(rows, index)
        if own > 0:
            found[tuple(path)] += own
    return found


def children_total(rows: list[tuple[int, int, str]], index: int) -> int:
    """The samples of row ``index``'s direct children."""
    depth = rows[index][0]
    child_depth = None
    total = 0
    for later_depth, later_count, _ in rows[index + 1 :]:
        if later_depth <= depth:
            break
        child_depth = later_depth if child_depth is None else child_depth
        if later_depth == child_depth:
            total += later_count
    return total


def short(frame: str) -> str:
    """A frame without its offset, address and source line."""
    return re.sub(r"\s+\+ [\d,]+\s+\[0x[0-9a-f,]+\].*$", "", frame).strip()


def category(stack: tuple[str, ...]) -> tuple[str, str]:
    """The stack's category and the innermost frame its rule matched (the leaf for "other")."""
    if any(wait in stack[-1] for wait in WAITS):
        return "waiting", stack[-1]
    for name, rule in CATEGORIES:
        for frame in reversed(stack):
            if rule.search(frame):
                return name, frame
    return "other", stack[-1]


def step(stack: tuple[str, ...]) -> str:
    for name, rule in STEPS:
        if any(rule.search(frame) for frame in stack):
            return name
    return "other"


def percent(count: int, total: int) -> str:
    return f"{100 * count / max(total, 1):5.1f}%"


def report(paths: list[Path], top: int, frames: str | None) -> None:
    all_stacks: Counter[tuple[str, ...]] = Counter()
    for path in paths:
        all_stacks.update(stacks(main_thread(path.read_text(errors="replace"))))
    by_category: Counter[str] = Counter()
    by_step: Counter[str] = Counter()
    leaves: dict[str, Counter[str]] = {}
    app_frames: Counter[str] = Counter()
    matched: Counter[str] = Counter()
    pattern = re.compile(frames) if frames else None
    for stack, count in all_stacks.items():
        name, frame = category(stack)
        by_category[name] += count
        if name == "waiting":
            continue
        by_step[step(stack)] += count
        leaves.setdefault(name, Counter())[short(frame)] += count
        # Inclusive: each distinct app frame on the stack once.
        for frame in {short(frame) for frame in stack if APP.search(frame)}:
            app_frames[frame] += count
        if pattern:
            for frame in {short(frame) for frame in stack if pattern.search(frame)}:
                matched[frame] += count
    busy = sum(count for name, count in by_category.items() if name != "waiting")
    total = busy + by_category["waiting"]
    print(f"main thread: {busy} on-CPU samples of {total} ({percent(busy, total).strip()})")
    print("by what the work was:")
    for name, count in by_category.most_common():
        if name == "waiting":
            continue
        print(f"  {percent(count, busy)}  {count:6d}  {name}")
        for leaf, leaf_count in leaves[name].most_common(4):
            print(f"                  {percent(leaf_count, busy)}  {leaf[:100]}")
    print("by the step of the frame it ran in:")
    for name, count in by_step.most_common():
        print(f"  {percent(count, busy)}  {count:6d}  {name}")
    print(f"app frames, inclusive (top {top}):")
    for frame, count in app_frames.most_common(top):
        print(f"  {percent(count, busy)}  {frame[:130]}")
    if pattern:
        print(f"frames matching {frames!r}, inclusive:")
        for frame, count in matched.most_common(top):
            print(f"  {percent(count, busy)}  {frame[:130]}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument("--top", type=int, default=25)
    parser.add_argument("--frames", help="also list inclusive samples of frames matching this")
    args = parser.parse_args()
    report(args.reports, args.top, args.frames)


if __name__ == "__main__":
    main()
