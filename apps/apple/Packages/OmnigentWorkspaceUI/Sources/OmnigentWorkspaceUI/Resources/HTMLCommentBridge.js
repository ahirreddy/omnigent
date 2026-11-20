"use strict";

// The HTML preview's comment bridge, ported from the web's htmlCommentBridgeRuntime.js. It runs
// as a user script in its own content world, so the page's scripts can neither see nor spoof
// it: it reports the reader's selection (its text and which copy of that text it is) and clicks
// on commented text to the app, and paints the comments' highlights with the CSS Custom
// Highlight API. The app sets the comments with `omniComments.setComments` and the selected one
// with `omniComments.setActive`.
(() => {
  const handler = window.webkit?.messageHandlers?.omniComments;
  if (!handler || !document.body) return;

  let comments = []; // [{ id, anchor_content, occ }]
  let active = null; // { comment_id, anchor_content, occ } | null
  let activeRanges = []; // ranges of the selected comment, for scrolling to it
  let ranges = []; // [{ id, range }] for hit-testing clicks

  function send(message) {
    handler.postMessage(message);
  }

  // Flat index of the visible text nodes, so an anchor spanning several nodes is one Range.
  function buildIndex() {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const tag = node.parentElement?.tagName;
        if (!tag || tag === "SCRIPT" || tag === "STYLE" || tag === "NOSCRIPT") {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    const nodes = [];
    let text = "";
    let node;
    while ((node = walker.nextNode())) {
      nodes.push({ node, start: text.length });
      text += node.nodeValue;
    }
    return { nodes, text };
  }

  function locate(nodes, position) {
    for (const entry of nodes) {
      if (position <= entry.start + entry.node.nodeValue.length) {
        return { node: entry.node, offset: position - entry.start };
      }
    }
    const last = nodes[nodes.length - 1];
    return last ? { node: last.node, offset: last.node.nodeValue.length } : null;
  }

  // Runs of whitespace (every code point through U+0020) collapse to one space; `map` takes a
  // normalized index back to the raw offset, with a trailing sentinel.
  function normalize(text) {
    let norm = "";
    const map = [];
    let previousSpace = false;
    for (let index = 0; index < text.length; index++) {
      const character = text.charAt(index);
      if (character <= " ") {
        if (previousSpace) continue;
        norm += " ";
        previousSpace = true;
      } else {
        norm += character;
        previousSpace = false;
      }
      map.push(index);
    }
    map.push(text.length);
    return { norm, map };
  }

  // Every match of the anchor in the normalized document text, as Ranges.
  function anchorRanges(index, haystack, anchor) {
    const found = [];
    const needle = normalize((anchor || "").trim()).norm.trim();
    if (!needle) return found;
    let from = 0;
    for (let guard = 0; guard < 1000; guard++) {
      const at = haystack.norm.indexOf(needle, from);
      if (at === -1) break;
      const start = locate(index.nodes, haystack.map[at]);
      const end = locate(index.nodes, haystack.map[at + needle.length]);
      if (start && end) {
        const range = document.createRange();
        range.setStart(start.node, start.offset);
        range.setEnd(end.node, end.offset);
        found.push(range);
      }
      from = at + Math.max(1, needle.length);
    }
    return found;
  }

  // The raw offset of a DOM boundary in the flat text: a text node maps directly, an element
  // boundary to the first indexed text node at or after it. -1 when unresolved.
  function flatOffset(index, node, offset) {
    if (node.nodeType === Node.TEXT_NODE) {
      const entry = index.nodes.find((candidate) => candidate.node === node);
      return entry ? entry.start + offset : -1;
    }
    const boundary = document.createRange();
    boundary.setStart(node, offset);
    const entry = index.nodes.find((candidate) => boundary.comparePoint(candidate.node, 0) >= 0);
    return entry ? entry.start : -1;
  }

  // Which copy (0-based, document order) of the selected text the selection is, so the comment
  // anchors to the one the reader picked.
  function selectionOccurrence(range, text) {
    const index = buildIndex();
    const start = flatOffset(index, range.startContainer, range.startOffset);
    if (start === -1) return 0;
    const haystack = normalize(index.text);
    const needle = normalize((text || "").trim()).norm.trim();
    if (!needle) return 0;
    let count = 0;
    let from = 0;
    for (let guard = 0; guard < 1000; guard++) {
      const at = haystack.norm.indexOf(needle, from);
      if (at === -1 || haystack.map[at] >= start) break;
      count++;
      from = at + Math.max(1, needle.length);
    }
    return count;
  }

  const style = document.createElement("style");
  style.textContent =
    "::highlight(omni-comment){background-color:rgba(255,204,0,0.3);}" +
    "::highlight(omni-comment-active){background-color:rgba(255,204,0,0.6);}";
  (document.head || document.documentElement).appendChild(style);

  function repaint() {
    const index = buildIndex();
    const haystack = normalize(index.text);
    ranges = [];
    const base = [];
    const selected = [];
    for (const comment of comments) {
      const found = anchorRanges(index, haystack, comment.anchor_content);
      // Only the copy the comment is on; a missing or stale copy shows them all.
      const picked =
        typeof comment.occ === "number" && comment.occ >= 0 && comment.occ < found.length
          ? [found[comment.occ]]
          : found;
      const isActive = active && active.comment_id === comment.id;
      for (const range of picked) {
        ranges.push({ id: comment.id, range });
        (isActive ? selected : base).push(range);
      }
    }
    activeRanges = selected;
    CSS.highlights.set("omni-comment", new Highlight(...base));
    CSS.highlights.set("omni-comment-active", new Highlight(...selected));
  }

  // Centers the selected comment's first range, only when it is off screen.
  function scrollActiveIntoView() {
    const range = activeRanges[0];
    if (!range) return;
    const rect = range.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) return;
    const viewport = window.innerHeight || document.documentElement.clientHeight;
    const top = window.scrollY + rect.top;
    if (top >= window.scrollY && top + rect.height <= window.scrollY + viewport) return;
    const target = top - viewport / 2 + rect.height / 2;
    window.scrollTo({ top: Math.max(0, target), behavior: "smooth" });
  }

  function caretRange(x, y) {
    if (document.caretRangeFromPoint) return document.caretRangeFromPoint(x, y);
    const position = document.caretPositionFromPoint?.(x, y);
    if (!position) return null;
    const range = document.createRange();
    range.setStart(position.offsetNode, position.offset);
    range.collapse(true);
    return range;
  }

  // The non-empty selection, or null.
  function currentSelection() {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0) return null;
    const text = selection.toString();
    if (selection.isCollapsed || !text.trim()) return null;
    return { range: selection.getRangeAt(0), text };
  }

  function emitSelection() {
    const current = currentSelection();
    if (!current) return false;
    send({
      type: "selection",
      text: current.text,
      occ: selectionOccurrence(current.range, current.text),
    });
    return true;
  }

  // A saved comment's highlight sits under the native selection; drop a selection it covers.
  function clearSelectionIfCommented() {
    const current = currentSelection();
    if (!current) return;
    const selected = normalize(current.text).norm.trim();
    if (!selected) return;
    const covered = comments.some(
      (comment) => normalize(comment.anchor_content || "").norm.trim() === selected,
    );
    if (covered) window.getSelection()?.removeAllRanges();
  }

  function onMouseUp(event) {
    if (emitSelection()) return;
    // A plain click: inside a comment's text, it selects that comment.
    const caret = caretRange(event.clientX, event.clientY);
    if (caret) {
      const hit = ranges.find((entry) =>
        entry.range.isPointInRange(caret.startContainer, caret.startOffset),
      );
      if (hit) {
        send({ type: "commentClick", id: hit.id });
        return;
      }
    }
    send({ type: "selectionCleared" });
  }

  // Keyboard, touch and programmatic selections, which mouseup misses; mouseup owns clearing.
  let selectionTimer = null;
  document.addEventListener("selectionchange", () => {
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(emitSelection, 150);
  });

  function zoomAction(event) {
    if (!(event.metaKey || event.ctrlKey) || event.altKey) return null;
    if (event.key === "=" || event.key === "+" || event.code === "NumpadAdd") return "in";
    if (event.key === "-" || event.key === "_" || event.code === "NumpadSubtract") return "out";
    if (event.key === "0" || event.code === "Numpad0") return "reset";
    return null;
  }

  // The zoom shortcuts zoom only this preview, as on the web.
  window.addEventListener("keydown", (event) => {
    if (event.defaultPrevented) return;
    const action = zoomAction(event);
    if (!action) return;
    event.preventDefault();
    send({ type: "zoom", action });
  });

  document.addEventListener("mouseup", onMouseUp, true);

  window.omniComments = {
    setComments(list) {
      comments = Array.isArray(list) ? list : [];
      clearSelectionIfCommented();
      repaint();
    },
    setActive(next) {
      const previous = active?.comment_id ?? null;
      active = next && next.comment_id ? next : null;
      repaint();
      // Only a newly selected comment scrolls, so a refresh keeps the reader's place.
      if (active && active.comment_id !== previous) scrollActiveIntoView();
    },
  };
  send({ type: "ready" });
})();
