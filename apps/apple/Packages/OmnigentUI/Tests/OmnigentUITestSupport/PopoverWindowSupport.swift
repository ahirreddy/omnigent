#if os(macOS)
  import AppKit
  import OmnigentViewTesting

  extension OffscreenWindow {
    /// The popover this window opened. Events don't reach it, but what it shows can be read.
    var popoverWindow: NSWindow? {
      NSApp.windows.first { candidate in
        candidate.isVisible && String(describing: Swift.type(of: candidate)).contains("Popover")
          && candidate.parent == window
      }
    }

    /// The text fields in the open popover, top to bottom.
    var popoverFieldValues: [String] {
      guard let root = popoverWindow?.contentView else { return [] }
      var fields: [NSTextField] = []
      var pending: [NSView] = [root]
      while let view = pending.popLast() {
        if let field = view as? NSTextField, field.isEditable { fields.append(field) }
        pending.append(contentsOf: view.subviews)
      }
      return
        fields
        .sorted { $0.convert($0.bounds, to: root).minY < $1.convert($1.bounds, to: root).minY }
        .map(\.stringValue)
    }
  }
#endif
