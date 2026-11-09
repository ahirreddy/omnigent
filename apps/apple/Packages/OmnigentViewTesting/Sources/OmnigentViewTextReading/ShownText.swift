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
      guard omnigent_view_debug_is_enabled() != 0, !tree.isEmpty,
        let data = _ViewDebug.serializedData(tree)
      else { throw OffscreenWindowError.notFound("SwiftUI's view tree") }
      var found: [String] = []
      ShownTextReader.collect(try JSONSerialization.jsonObject(with: data), into: &found)
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

  /// Walks the JSON of `_ViewDebug` for the resolved strings of the views that draw text.
  private enum ShownTextReader {
    static func collect(_ value: Any, into found: inout [String]) {
      if let nodes = value as? [Any] {
        for node in nodes { collect(node, into: &found) }
        return
      }
      guard let node = value as? [String: Any] else { return }
      for property in node["properties"] as? [[String: Any]] ?? [] {
        guard let attribute = property["attribute"] as? [String: Any],
          attribute["type"] as? String == "SwiftUI.StyledTextContentView",
          let string = cachedString(in: attribute)
        else { continue }
        found.append(plainText(string))
      }
      if let children = node["children"] { collect(children, into: &found) }
    }

    /// The `string` under the attribute's text cache, as `NSAttributedString` describes itself.
    private static func cachedString(in attribute: [String: Any]) -> String? {
      if attribute["name"] as? String == "string", let value = attribute["value"] as? String {
        return value
      }
      for child in attribute["subattributes"] as? [[String: Any]] ?? [] {
        if let found = cachedString(in: child) { return found }
      }
      return nil
    }

    /// Drops the attribute dictionary after each run: `text{\n  attributes\n}more{\n ...\n}`.
    private static func plainText(_ description: String) -> String {
      description.replacing(/\{\n[\s\S]*?\n\}/, with: "")
    }
  }
#endif
