internal import Foundation

/// The element an action targets: a ref from a snapshot, or a CSS selector.
nonisolated enum AgentElementTarget: Sendable, Hashable {
  /// A `[ref=N]` from `browser_snapshot`, optionally checked against its snapshot ID.
  case ref(Int, snapshotID: String?)
  /// A CSS selector.
  case selector(String)
}

/// In-page scripts for agent actions, ported from `web/electron/src/browserActionScript.mjs`
/// so refs, snapshot IDs and stale-ref errors behave as on the desktop app. Every script
/// returns a JSON string; failures come back as `{"error": "..."}` rather than exceptions, so
/// both engines report the same message.
nonisolated enum AgentBrowserScripts {
  /// A JavaScript literal for `value`, which must be made of strings: those always encode.
  static func literal(_ value: some Encodable) -> String {
    let data = try? JSONEncoder().encode(value)
    precondition(data != nil, "Encoding strings as JSON cannot fail.")
    return String(bytes: data ?? Data(), encoding: .utf8) ?? ""
  }

  /// The accessibility-style tree with stable `[ref=N]` ids. Refs live in
  /// `window.__omni_refs__` under `window.__omni_snapshot_id__`; a new snapshot replaces them.
  /// Returns `{snapshot_id, url, title, tree}`.
  static let snapshot = #"""
    (() => {
      const snapshotId = (crypto && crypto.randomUUID) ? crypto.randomUUID()
        : ('snap-' + Date.now() + '-' + Math.random().toString(36).slice(2, 10));
      window.__omni_refs__ = new Map();
      window.__omni_snapshot_id__ = snapshotId;
      let nextRef = 0;
      const lines = [];
      const TAG_ROLE = {
        a: 'link', button: 'button', textarea: 'textbox', select: 'combobox',
        nav: 'navigation', main: 'main', header: 'banner', footer: 'contentinfo',
        form: 'form', section: 'region', article: 'article', aside: 'complementary',
        ul: 'list', ol: 'list', li: 'listitem', img: 'image', label: 'label',
        table: 'table', tr: 'row', td: 'cell', th: 'columnheader',
        dialog: 'dialog', summary: 'button', details: 'group',
      };
      const isInteractiveTag = (tag) => tag === 'a' || tag === 'button' || tag === 'input' ||
        tag === 'textarea' || tag === 'select' || tag === 'label' || tag === 'summary';
      const isHeading = (tag) => tag && tag.length === 2 && tag[0] === 'h' && tag[1] >= '1' &&
        tag[1] <= '6';
      function getRole(el) {
        const explicit = el.getAttribute && el.getAttribute('role');
        if (explicit) return explicit;
        const tag = el.tagName && el.tagName.toLowerCase();
        if (!tag) return null;
        if (tag === 'input') {
          const t = (el.type || 'text').toLowerCase();
          if (t === 'submit' || t === 'button' || t === 'reset') return 'button';
          if (t === 'checkbox') return 'checkbox';
          if (t === 'radio') return 'radio';
          if (t === 'range') return 'slider';
          if (t === 'hidden') return null;
          return 'textbox';
        }
        if (isHeading(tag)) return 'heading';
        if (TAG_ROLE[tag]) return TAG_ROLE[tag];
        if (el.hasAttribute && (el.hasAttribute('tabindex') || el.hasAttribute('onclick'))) {
          return 'generic';
        }
        return null;
      }
      function getName(el, depth = 0) {
        if (depth > 4) return '';
        if (el.getAttribute) {
          for (const attribute of ['aria-label', 'alt', 'placeholder', 'title']) {
            const value = el.getAttribute(attribute);
            if (value) return value;
          }
        }
        const tag = el.tagName && el.tagName.toLowerCase();
        if (tag === 'input' && el.value && el.type !== 'password') {
          return String(el.value).slice(0, 80);
        }
        let text = '';
        for (const node of el.childNodes) {
          if (node.nodeType === 3) text += node.textContent;
          else if (node.nodeType === 1) {
            const childTag = node.tagName && node.tagName.toLowerCase();
            if (depth === 0 && isInteractiveTag(childTag)) continue;
            text += getName(node, depth + 1);
          }
          if (text.length > 80) break;
        }
        return text.trim().replace(/\s+/g, ' ').slice(0, 80);
      }
      function isVisible(el) {
        if (!el.getBoundingClientRect) return false;
        const style = window.getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden') return false;
        if (style.opacity === '0') return false;
        const rect = el.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      }
      function walk(el, depth) {
        if (!(el instanceof Element)) return;
        if (!isVisible(el)) return;
        const role = getRole(el);
        let childDepth = depth;
        if (role !== null && role !== 'generic') {
          const ref = ++nextRef;
          window.__omni_refs__.set(ref, new WeakRef(el));
          const name = getName(el);
          let line = '  '.repeat(depth) + '- ' + role;
          if (name) line += ' ' + JSON.stringify(name);
          line += ' [ref=' + ref + ']';
          lines.push(line);
          childDepth = depth + 1;
        }
        for (const child of el.children) walk(child, childDepth);
      }
      if (document.body) walk(document.body, 0);
      return JSON.stringify({
        snapshot_id: snapshotId, url: window.location.href, title: document.title,
        tree: lines.join('\n'),
      });
    })()
    """#

  /// Statements that set `el` to the target or throw the desktop app's precise error.
  static func findElement(_ target: AgentElementTarget) -> String {
    switch target {
    case .ref(let ref, let snapshotID):
      let idCheck =
        snapshotID.map { id in
          "if (window.__omni_snapshot_id__ !== \(literal(id))) throw new Error('snapshot ' + "
            + "\(literal(id)) + ' was superseded by ' + (window.__omni_snapshot_id__ || '(none)') "
            + "+ ' — call browser_snapshot again'); "
        } ?? ""
      return idCheck
        + "if (!window.__omni_refs__) throw new Error('no snapshot in this page — call "
        + "browser_snapshot first'); "
        + "if (!window.__omni_refs__.has(\(ref))) throw new Error('ref ' + \(ref) + ' not in "
        + "snapshot — call browser_snapshot again'); "
        + "const el = window.__omni_refs__.get(\(ref)).deref(); "
        + "if (!el) throw new Error('ref ' + \(ref) + ' was garbage-collected — call "
        + "browser_snapshot again'); "
    case .selector(let selector):
      return "const el = document.querySelector(\(literal(selector))); "
        + "if (!el) throw new Error('selector not found: ' + \(literal(selector))); "
    }
  }

  /// Wraps statements that may throw so the script returns `{"error": message}` instead.
  private static func guarded(_ body: String) -> String {
    "(() => { try { \(body) } catch (e) { return JSON.stringify({ error: String(e && "
      + "e.message || e) }); } })()"
  }

  /// Scrolls the target to the middle of the viewport and returns
  /// `{x, y, width, height, editable, tag}`, the center in viewport CSS pixels.
  static func locate(_ target: AgentElementTarget) -> String {
    guarded(
      findElement(target)
        + "el.scrollIntoView({ block: 'center', inline: 'center' }); "
        + "const r = el.getBoundingClientRect(); const tag = el.tagName.toLowerCase(); "
        + "const nonText = ['button', 'submit', 'reset', 'checkbox', 'radio', 'file', 'image', "
        + "'range', 'color', 'hidden']; "
        + "const editable = el.isContentEditable || tag === 'textarea' || (tag === 'input' && "
        + "!nonText.includes((el.type || 'text').toLowerCase())); "
        + "return JSON.stringify({ x: r.x + r.width / 2, y: r.y + r.height / 2, width: r.width, "
        + "height: r.height, editable, tag });")
  }

  /// Focuses the target and selects its contents, so typed text replaces them.
  static func focusAndSelect(_ target: AgentElementTarget) -> String {
    guarded(
      findElement(target)
        + "if (document.activeElement !== el && typeof el.focus === 'function') el.focus(); "
        + "if ((el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') && "
        + "typeof el.select === 'function') { el.select(); } "
        + "else if (el.isContentEditable) { const range = document.createRange(); "
        + "range.selectNodeContents(el); const selection = getSelection(); "
        + "selection.removeAllRanges(); selection.addRange(range); } "
        + "return JSON.stringify({ focused: document.activeElement === el });")
  }

  /// Focuses the target without selecting.
  static func focus(_ target: AgentElementTarget) -> String {
    guarded(
      findElement(target)
        + "if (typeof el.focus === 'function') el.focus(); "
        + "return JSON.stringify({ focused: document.activeElement === el });")
  }

  /// The target's `value` (inputs) or text (other elements).
  static func value(_ target: AgentElementTarget) -> String {
    guarded(
      findElement(target)
        + "const value = ('value' in el) ? String(el.value) : String(el.textContent || ''); "
        + "return JSON.stringify({ value, hasValue: 'value' in el });")
  }

  /// The viewport center, `{x, y}`.
  static let viewportCenter =
    "JSON.stringify({ x: window.innerWidth / 2, y: window.innerHeight / 2 })"

  /// `{href, readyState, title}` of the current document.
  static let documentState =
    "JSON.stringify({ href: location.href, readyState: document.readyState, "
    + "title: document.title })"
}
