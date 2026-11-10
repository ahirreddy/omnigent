#if os(macOS)
  public import AppKit
  import Foundation
  public import OmnigentViewTesting
  import SwiftUI
  import OmnigentViewDebugBootstrap

  /// Any SwiftUI host, whatever its content: a `List` row and a sheet each have their own.
  private protocol ViewTreeHosting {
    var viewTree: [_ViewDebug.Data] { get }
  }

  extension NSHostingView: ViewTreeHosting {
    fileprivate var viewTree: [_ViewDebug.Data] { _viewDebugData() }
  }

  // A test target opts in by depending on this product: linking it turns on SwiftUI's view tree
  // recording for that target's whole test process.
  extension OffscreenWindow {
    /// The text the view draws now, one string per text view, read from SwiftUI's view tree. Text
    /// that is laid out counts even when it is transparent or scrolled out of the window. That
    /// includes the rows a `List` has made and a sheet over the window, not rows it hasn't made.
    /// - Returns: The strings; they are not in layout order.
    /// - Throws: `OffscreenWindowError` when SwiftUI doesn't report its tree.
    public func shownText() throws -> [String] {
      try text(under: [window.contentView, window.attachedSheet?.contentView].compactMap(\.self))
    }

    /// The text the window's toolbar items draw now, which `shownText()` leaves out: a toolbar's
    /// views sit in the titlebar, outside the content view.
    /// - Returns: The strings; they are not in layout order.
    /// - Throws: `OffscreenWindowError` when SwiftUI doesn't report its tree.
    public func toolbarText() throws -> [String] {
      try text(under: window.toolbar?.items.compactMap(\.view) ?? [])
    }

    /// The text drawn under one view of the window, such as one row of a `List`.
    /// - Parameter view: A view in this window.
    /// - Returns: The strings; they are not in layout order.
    /// - Throws: `OffscreenWindowError` when SwiftUI doesn't report its tree.
    public func shownText(under view: NSView) throws -> [String] {
      try text(under: [view])
    }

    private func text(under roots: [NSView]) throws -> [String] {
      guard omnigent_view_debug_is_enabled() != 0, !host._viewDebugData().isEmpty else {
        throw OffscreenWindowError.notFound("SwiftUI's view tree")
      }
      var found: [String] = []
      var pending = roots
      while let view = pending.popLast() {
        if let hosting = view as? any ViewTreeHosting {
          for node in hosting.viewTree { try ShownTextReader.collect(node, into: &found) }
        }
        pending.append(contentsOf: view.subviews)
      }
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
