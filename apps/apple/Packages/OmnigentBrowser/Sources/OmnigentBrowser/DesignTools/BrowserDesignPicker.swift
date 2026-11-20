internal import CoreGraphics
internal import Foundation

/// Annotate's element picker: the page script that finds the element under a point, and the
/// check of its answer. Ported from the web's `designToolsPage.mjs`; the script is built from
/// checked numbers only, and everything it returns is the page's data, so it is validated.
nonisolated enum BrowserDesignPicker {
  /// The longest a field of the answer may be; the script sends 200 characters of text, but a
  /// page running the script in its own world could send more.
  static let fieldLimit = 1000

  /// The script answering with the element at a point given as a fraction of the viewport
  /// (`0...1` each way): JSON `{ element, rect, viewport, key }`, or JSON `null`. Fractions
  /// keep the point right at any page zoom.
  static func script(at fraction: CGPoint) -> String? {
    guard fraction.x.isFinite, fraction.y.isFinite else { return nil }
    let fractionX = min(max(Double(fraction.x), 0), 1)
    let fractionY = min(max(Double(fraction.y), 0), 1)
    return """
      (() => { \(describe)\(keyOf)\(deepAt)\
      const width = window.innerWidth, height = window.innerHeight; \
      const el = at(\(fractionX) * width, \(fractionY) * height); \
      if (!el || el === document.documentElement || el === document.body) return JSON.stringify(null); \
      const r = el.getBoundingClientRect(); \
      return JSON.stringify({ element: describe(el), \
      rect: { x: r.left, y: r.top, width: r.width, height: r.height }, \
      viewport: { width, height }, key: keyOf(el) }); })()
      """
  }

  /// `describe(el)`: what the messages say about an element.
  private static let describe =
    "const describe = (el) => { "
    + "const classes = typeof el.className === 'string' && el.className.trim() "
    + "? '.' + el.className.trim().split(/\\s+/).slice(0, 4).join('.') : ''; "
    + "return { tag: el.tagName.toLowerCase(), id: el.id ? '#' + el.id : '', classes, "
    + "text: (el.innerText || el.textContent || '').trim().slice(0, 200), "
    + "testId: el.getAttribute('data-testid') || '', "
    + "ariaLabel: el.getAttribute('aria-label') || '', "
    + "role: el.getAttribute('role') || '' }; }; "

  /// `keyOf(el)`: the same key for an element each time and never another's.
  private static let keyOf =
    "const keyOf = (el) => { const keys = window.omnigentElementKeys || "
    + "(window.omnigentElementKeys = new WeakMap()); let key = keys.get(el); "
    + "if (!key) { window.omnigentElementNext = (window.omnigentElementNext || 0) + 1; "
    + "key = 'e' + window.omnigentElementNext; keys.set(el, key); } return key; }; "

  /// `at(x, y)`: the element at a viewport point, inside any open shadow roots there.
  private static let deepAt =
    "const at = (x, y) => { let el = document.elementFromPoint(x, y); "
    + "while (el && el.shadowRoot) { const inner = el.shadowRoot.elementFromPoint(x, y); "
    + "if (!inner || inner === el) break; el = inner; } return el; }; "

  /// The script's answer, checked: `nil` for JSON `null`.
  /// - Throws: `BrowserError.scriptFailed` for an answer that isn't the picker's.
  static func hit(from answer: BrowserScriptValue) throws(BrowserError) -> BrowserDesignHit? {
    guard let json = answer.stringValue else {
      throw .scriptFailed(message: "The element picker gave no answer.")
    }
    let value = try BrowserScriptValue(jsonData: Data(json.utf8))
    if value == .null { return nil }
    guard case .object(let fields) = value, case .object(let element)? = fields["element"],
      let rect = Self.rect(fields["rect"]), let viewport = Self.size(fields["viewport"]),
      viewport.width > 0, viewport.height > 0
    else {
      throw .scriptFailed(message: "The element picker's answer was malformed.")
    }
    let field = { (name: String) in String((element[name]?.stringValue ?? "").prefix(fieldLimit)) }
    return BrowserDesignHit(
      element: BrowserDesignElement(
        tag: field("tag"), id: field("id"), classes: field("classes"), text: field("text"),
        testID: field("testId"), ariaLabel: field("ariaLabel"), role: field("role")),
      rect: rect, viewport: viewport,
      key: String((fields["key"]?.stringValue ?? "").prefix(fieldLimit)))
  }

  private static func rect(_ value: BrowserScriptValue?) -> CGRect? {
    guard case .object(let fields)? = value,
      let origin = point(fields["x"], fields["y"]), let size = size(value)
    else { return nil }
    return CGRect(origin: origin, size: size)
  }

  private static func size(_ value: BrowserScriptValue?) -> CGSize? {
    guard case .object(let fields)? = value,
      let width = finite(fields["width"]), let height = finite(fields["height"]),
      width >= 0, height >= 0
    else { return nil }
    return CGSize(width: width, height: height)
  }

  private static func point(_ first: BrowserScriptValue?, _ second: BrowserScriptValue?)
    -> CGPoint?
  {
    guard let horizontal = finite(first), let vertical = finite(second) else { return nil }
    return CGPoint(x: horizontal, y: vertical)
  }

  private static func finite(_ value: BrowserScriptValue?) -> Double? {
    guard let number = value?.numberValue, number.isFinite else { return nil }
    return number
  }
}

nonisolated extension BrowserDesignHit {
  /// Whether `other` is the same element, by its key and every field the messages read.
  func isSameElement(as other: Self) -> Bool {
    key == other.key && element == other.element
  }
}
