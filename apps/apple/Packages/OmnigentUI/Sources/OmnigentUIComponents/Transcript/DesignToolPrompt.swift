public import Foundation

/// What a page's element picker reports about one element, for an Annotate message. Every
/// field comes from the page, so ``DesignToolPrompt`` sanitizes each one.
nonisolated public struct DesignPromptElement: Hashable, Sendable {
  /// The tag, lowercase (`p`).
  public var tag: String?
  /// The id with its `#` (`#blurb`).
  public var id: String?
  /// Up to four classes, each with its `.` (`.card.large`).
  public var classes: String?
  /// The element's text.
  public var text: String?
  /// Its `data-testid`.
  public var testID: String?
  /// Its `aria-label`.
  public var ariaLabel: String?
  /// Its `role`.
  public var role: String?
  /// A component name the picker found (`CheckoutButton`).
  public var component: String?

  /// Creates an element.
  /// - Parameters:
  ///   - tag: Tag.
  ///   - id: Id with `#`.
  ///   - classes: Classes with `.`.
  ///   - text: Text.
  ///   - testID: `data-testid`.
  ///   - ariaLabel: `aria-label`.
  ///   - role: `role`.
  ///   - component: Component name.
  public init(
    tag: String? = nil, id: String? = nil, classes: String? = nil, text: String? = nil,
    testID: String? = nil, ariaLabel: String? = nil, role: String? = nil,
    component: String? = nil
  ) {
    self.tag = tag
    self.id = id
    self.classes = classes
    self.text = text
    self.testID = testID
    self.ariaLabel = ariaLabel
    self.role = role
    self.component = component
  }
}

/// The Browser design tools' chat messages, worded as the web's (`buildDesignModePrompt` and
/// `buildDrawPrompt`), so the web and ``DesignRequest`` both read them back.
nonisolated public enum DesignToolPrompt {
  /// The longest an element field may be, in UTF-16 units as the web counts.
  static let fieldLimit = 200
  /// Annotate's line when its request goes without the element's screenshot.
  public static let noScreenshotLine = "Screenshot: none attached (it couldn't be taken)"
  /// Draw's words when the note is empty.
  public static let defaultDrawRequest = "Make the changes I marked on the attached screenshot."

  /// Annotate's message: what the user asked, then the element's `[Design Mode — …]` block.
  /// - Parameters:
  ///   - element: The picked element (untrusted page data).
  ///   - request: What the user typed, sent as typed.
  ///   - screenshotAttached: `false` adds the line saying it goes without a screenshot.
  /// - Returns: The message.
  public static func annotate(
    element: DesignPromptElement, request: String, screenshotAttached: Bool = true
  ) -> String {
    let text = sanitized(element.text)
    let ariaLabel = sanitized(element.ariaLabel)
    let role = sanitized(element.role)
    let lines = [
      "[Design Mode \u{2014} modify this element in the browser preview]",
      "Element: \(displayName(element))",
      "CSS selector: \(selector(element))",
      text.isEmpty ? "" : "Text: \"\(text)\"",
      ariaLabel.isEmpty ? "" : "Aria-label: \"\(ariaLabel)\"",
      role.isEmpty ? "" : "Role: \(role)",
      screenshotAttached ? "" : noScreenshotLine,
    ].filter { !$0.isEmpty }
    return "\(request)\n\n---\n\(lines.joined(separator: "\n"))\n---"
  }

  /// Draw's message: the note (or ``defaultDrawRequest``) and what the screenshot shows.
  /// - Parameters:
  ///   - note: The user's note.
  ///   - url: The page drawn on.
  /// - Returns: The message.
  public static func draw(note: String, url: URL?) -> String {
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    let request = trimmed.isEmpty ? defaultDrawRequest : trimmed
    return "\(request)\n\n---\n[Design Mode \u{2014} marked-up screenshot of the browser preview]\n"
      + "Page: \(pageAddress(url))\n"
      + "The attached screenshot shows the page with my marks drawn on it.\n---"
  }

  /// The page as the agent is told it: its origin only, since a path or query can carry a
  /// credential and the screenshot shows the page.
  /// - Parameter url: The page.
  /// - Returns: `https://example.test`, `file: page`, or `(unknown page)`.
  public static func pageAddress(_ url: URL?) -> String {
    guard let url, let scheme = url.scheme?.lowercased() else { return "(unknown page)" }
    guard scheme == "http" || scheme == "https" else { return "\(scheme): page" }
    guard let host = url.host(percentEncoded: true)?.lowercased(), !host.isEmpty else {
      return "(unknown page)"
    }
    let shownHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    let defaultPort = scheme == "http" ? 80 : 443
    guard let port = url.port, port != defaultPort else { return "\(scheme)://\(shownHost)" }
    return "\(scheme)://\(shownHost):\(port)"
  }

  /// A page field made safe for the block: control characters and line separators become
  /// spaces, runs of space collapse, and it is trimmed, then clamped to ``fieldLimit``.
  static func sanitized(_ value: String?) -> String {
    guard let value else { return "" }
    var scalars = String.UnicodeScalarView()
    var pendingSpace = false
    for scalar in value.unicodeScalars {
      if isSpace(scalar) {
        pendingSpace = !scalars.isEmpty
        continue
      }
      if pendingSpace { scalars.append(" ") }
      pendingSpace = false
      scalars.append(scalar)
    }
    var clamped = String.UnicodeScalarView()
    var units = 0
    for scalar in scalars {
      units += scalar.utf16.count
      guard units <= fieldLimit else { break }
      clamped.append(scalar)
    }
    return String(clamped)
  }

  /// Whitespace as JavaScript's `\s` reads it, plus the control characters the web strips.
  private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    if value <= 0x1F || (0x7F...0x9F).contains(value) || value == 0x2028 || value == 0x2029 {
      return true
    }
    return scalar.properties.isWhitespace || value == 0xFEFF
  }

  /// The element's name: the component the picker found, else its tag.
  private static func displayName(_ element: DesignPromptElement) -> String {
    let component = sanitized(element.component)
    if !component.isEmpty { return "<\(component)>" }
    let tag = sanitized(element.tag)
    return "<\(tag.isEmpty ? "element" : tag)>"
  }

  /// A selector for the element: its test id, else its id, else its tag and classes.
  private static func selector(_ element: DesignPromptElement) -> String {
    let testID = sanitized(element.testID)
    if !testID.isEmpty { return "[data-testid=\"\(testID)\"]" }
    let id = sanitized(element.id)
    if !id.isEmpty { return id }
    return sanitized(element.tag) + sanitized(element.classes)
  }
}
