#if DEBUG
  import AppKit
  import ObjectiveC

  /// What ``ChaosDriver`` writes besides its steps: window names and every Objective-C exception.
  enum ChaosLog {
    /// A window's title, or its class and level when it has none (sheets, panels, popovers).
    @MainActor
    static func describe(_ window: NSWindow) -> String {
      let kind =
        "\(Swift.type(of: window)) level=\(window.level.rawValue) screen=\(window.screen != nil)"
      return window.title.isEmpty ? "<\(kind)>" : "\"\(window.title)\""
    }

    /// Throws logged so far; a loop that throws on every pass stops being logged after this.
    nonisolated(unsafe) private static var thrownCount = 0

    /// Logs uncaught exceptions with their reasons, which the system log keeps private, and every
    /// throw before anything catches it: one AppKit catches still leaves Swift's exclusivity and
    /// executor records of the frames it unwound, and a later access crashes far away.
    static func recordExceptions() {
      NSSetUncaughtExceptionHandler { exception in Self.recordUncaught(exception) }
      objc_setExceptionPreprocessor { exception in
        if let exception = exception as? NSException { Self.recordThrown(exception) }
        return exception
      }
    }

    nonisolated private static func recordUncaught(_ exception: NSException) {
      let stack = exception.callStackSymbols.prefix(40).joined(separator: "\n")
      append("EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "no reason")\n\(stack)\n")
    }

    nonisolated private static func recordThrown(_ exception: NSException) {
      unsafe thrownCount += 1
      guard unsafe thrownCount <= 200 else { return }
      let stack = Thread.callStackSymbols.dropFirst(2).prefix(30).joined(separator: "\n")
      append("THROWN \(exception.name.rawValue): \(exception.reason ?? "no reason")\n\(stack)\n")
      if exception.reason?.contains("Update Constraints in Window") == true, Thread.isMainThread {
        append(MainActor.assumeIsolated { viewsNeedingConstraints() })
      }
    }

    /// Logs a menu item that AppKit titled with nil (``MenuTitleGuard``), with the toolbars whose
    /// overflow menus are the usual source.
    nonisolated static func recordNilMenuTitle() {
      let stack = Thread.callStackSymbols.dropFirst(2).prefix(20).joined(separator: "\n")
      append("NIL MENU TITLE\n\(stack)\n")
      if Thread.isMainThread { append(MainActor.assumeIsolated { toolbarItems() }) }
    }

    /// Every visible window's toolbar items with their labels, read without bridging a nil one.
    @MainActor
    private static func toolbarItems() -> String {
      var lines: [String] = []
      for window in NSApp.windows where window.isVisible {
        guard let toolbar = window.toolbar else { continue }
        lines.append("TOOLBAR ITEMS in \(describe(window))")
        for item in toolbar.items {
          let label = item.value(forKey: "label").map { "\"\($0)\"" } ?? "nil"
          let menu = item.menuFormRepresentation.map { "\"\($0.title)\"" } ?? "nil"
          lines.append(
            "  \(item.itemIdentifier.rawValue) label=\(label) menu=\(menu) visible=\(item.isVisible)"
          )
        }
      }
      return lines.joined(separator: "\n") + "\n"
    }

    /// The views still asking for a constraint pass, deepest last: the one in a loop is among
    /// them, and a hosting view's type names the SwiftUI view it shows.
    @MainActor
    private static func viewsNeedingConstraints() -> String {
      var lines: [String] = []
      var deepest: NSView?
      func visit(_ view: NSView, depth: Int) {
        guard lines.count < 40 else { return }
        if view.needsUpdateConstraints {
          let type = String(describing: Swift.type(of: view)).prefix(400)
          lines.append(
            "  depth=\(depth) \(Int(view.frame.width))x\(Int(view.frame.height)) \(type)")
          deepest = view
        }
        for subview in view.subviews { visit(subview, depth: depth + 1) }
      }
      for window in NSApp.windows where window.isVisible {
        lines.append("NEEDS CONSTRAINTS in \(describe(window))")
        deepest = nil
        if let frame = unsafe window.contentView?.superview { visit(frame, depth: 0) }
        if let deepest { lines.append(placement(of: deepest)) }
      }
      return lines.joined(separator: "\n") + "\n"
    }

    /// Where `view` sits: its ancestors' types and frames, its safe area and its children.
    @MainActor
    private static func placement(of view: NSView) -> String {
      func name(_ view: NSView) -> String {
        "\(String(describing: Swift.type(of: view)).prefix(120)) \(view.frame)"
      }
      var ancestors: [String] = []
      var current = unsafe view.superview
      while let ancestor = current {
        ancestors.append("    in " + name(ancestor))
        current = unsafe ancestor.superview
      }
      let insets = view.safeAreaInsets
      let children = view.subviews.map { "    child " + name($0) }
      return
        ([
          "  deepest \(name(view)) safeArea=\(insets.top),\(insets.left),\(insets.bottom),"
            + "\(insets.right)"
        ] + children + ancestors)
        .joined(separator: "\n")
    }

    /// Appends `text` to the chaos log, or says on standard error why it could not.
    nonisolated private static func append(_ text: String) {
      guard let path = UserDefaults.standard.string(forKey: "OmnigentChaosLog") else { return }
      do {
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try log.seekToEnd()
        try log.write(contentsOf: Data(text.utf8))
      } catch {
        FileHandle.standardError.write(Data("chaos log write failed: \(error)\n\(text)".utf8))
      }
    }
  }
#endif
