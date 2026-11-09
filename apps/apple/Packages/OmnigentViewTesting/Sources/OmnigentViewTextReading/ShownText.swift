#if os(macOS)
  import Foundation
  public import OmnigentViewTesting
  import SwiftUI
  import OmnigentViewDebugBootstrap

  // A test target opts in by depending on this product: linking it turns on SwiftUI's view tree
  // recording for that target's whole test process.
  extension OffscreenWindow {
    /// The text the view draws now, one string per text view, read from SwiftUI's view tree. Text
    /// that is laid out counts even when it is transparent or scrolled out of the window.
    /// - Returns: The strings; they are not in layout order.
    /// - Throws: `OffscreenWindowError` when SwiftUI doesn't report its tree.
    public func shownText() throws -> [String] {
      let tree = host._viewDebugData()
      guard omnigent_view_debug_is_enabled() != 0, !tree.isEmpty else {
        throw OffscreenWindowError.notFound("SwiftUI's view tree")
      }
      var found: [String] = []
      for node in tree { try ShownTextReader.collect(node, into: &found) }
      return found
    }

    /// Whether any drawn text contains `text`.
    /// - Parameter text: The text to look for.
    /// - Returns: Whether it is drawn.
    /// - Throws: `OffscreenWindowError` when SwiftUI doesn't report its tree.
    public func shows(_ text: String) throws -> Bool {
      try shownText().contains { $0.contains(text) }
    }
  }

  /// Walks `_ViewDebug` values for the strings of the views that draw text. Its JSON form is no use
  /// here: one value it can't encode replaces the whole tree with an error, which reads as no text.
  private enum ShownTextReader {
    static func collect(_ node: _ViewDebug.Data, into found: inout [String]) throws {
      let mirror = Mirror(reflecting: node)
      // A SwiftUI that lays this out differently must fail the test, not read as showing nothing.
      guard let properties = mirror.descendant("data") as? [_ViewDebug.Property: Any],
        let children = mirror.descendant("childData") as? [_ViewDebug.Data]
      else { throw OffscreenWindowError.notFound("SwiftUI's view tree") }
      if let value = properties[.value], "\(type(of: value))" == "StyledTextContentView",
        let string = attributedString(in: value, depth: 0)
      {
        found.append(string)
      }
      for child in children { try collect(child, into: &found) }
    }

    /// The resolved string a text view caches, a few levels into its private storage.
    private static func attributedString(in value: Any, depth: Int) -> String? {
      if let text = value as? NSAttributedString { return text.string }
      guard depth < 6 else { return nil }
      for child in Mirror(reflecting: value).children {
        if let found = attributedString(in: child.value, depth: depth + 1) { return found }
      }
      return nil
    }
  }
#endif
