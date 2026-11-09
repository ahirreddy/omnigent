#if DEBUG
  import AppKit
  import OSLog
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

    /// Starts what a run records beyond its steps.
    static func startDiagnostics() {
      recordExceptions()
      ChaosWindows.probeFrames()
      if let path = UserDefaults.standard.string(forKey: "OmnigentChaosLog") {
        ChaosHangWatch(path: path).start()
      }
    }

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
        if let deepest {
          lines.append(placement(of: deepest))
          lines += owningToolbarItems(of: deepest)
        }
      }
      return lines.joined(separator: "\n") + "\n"
    }

    /// The toolbar items, in any window, whose view holds `view`: a full-screen window's items
    /// sit in a window of their own.
    @MainActor
    private static func owningToolbarItems(of view: NSView) -> [String] {
      NSApp.windows.compactMap(\.toolbar).flatMap(\.items).compactMap { item in
        guard let itemView = item.view, view === itemView || view.isDescendant(of: itemView)
        else { return nil }
        let label = item.value(forKey: "label").map { "\($0)" } ?? "nil"
        return "  toolbar item \(item.itemIdentifier.rawValue) label=\"\(label)\" "
          + "tip=\"\(item.toolTip ?? "")\" view=\(Swift.type(of: itemView))"
      }
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

    /// What has focus in `window` when nothing there takes text, and whether the composer
    /// could be focused instead.
    @MainActor
    static func describeTextFocus(in window: NSWindow) -> String {
      let focused = window.firstResponder.map { "\(Swift.type(of: $0))" } ?? "nothing"
      let command = ChaosMenu.items().contains { $0.path.hasSuffix("> Focus Composer") }
      return "\(focused) takes no text in \(describe(window)), "
        + "Focus Composer \(command ? "enabled" : "disabled")"
    }

    @MainActor private static var lastEditedField: String?

    /// ``editedField()`` when it differs from the last call's.
    @MainActor
    static func changedEditedField() -> String? {
      let field = editedField()
      defer { lastEditedField = field }
      return field == lastEditedField ? nil : field
    }

    /// The key window's editable single-line field when its text has line breaks or runs well
    /// past what a paste leaves (``SingleLinePasteGuard``), so typing after a paste does not
    /// count: what a stall clicking in it needs.
    @MainActor
    private static func editedField() -> String? {
      guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor,
        let field = editor.delegate as? NSTextField, field.isEditable
      else { return nil }
      let cell = field.cell
      guard cell?.usesSingleLineMode == true || cell?.isScrollable == true else { return nil }
      let text = editor.string
      let lines = text.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
      guard lines > 1 || text.utf16.count > SingleLinePasteGuard.maximumLength * 2 else {
        return nil
      }
      return "FIELD \(Swift.type(of: field)) editor=\(Swift.type(of: editor)) "
        + "lines=\(lines) length=\(text.utf16.count) singleLine=\(cell?.usesSingleLineMode ?? false) "
        + "scrollable=\(cell?.isScrollable ?? false) id=\(field.identifier?.rawValue ?? "")"
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
  /// The log a chaos run writes each step to, also sent to the unified log.
  final class ChaosLogFile {
    private static let logger = Logger(subsystem: "ai.omnigent.chaos", category: "driver")
    private let file: FileHandle

    /// Starts an empty log at `path`, or is `nil` (and says so) when it cannot be written.
    init?(path: String) {
      guard FileManager.default.createFile(atPath: path, contents: nil),
        let file = FileHandle(forWritingAtPath: path)
      else {
        Self.logger.error("Cannot write the chaos log at \(path, privacy: .public)")
        return nil
      }
      self.file = file
    }

    func write(_ line: String) {
      Self.logger.notice("\(line, privacy: .public)")
      do {
        try file.seekToEnd()
        try file.write(contentsOf: Data((line + "\n").utf8))
      } catch {
        Self.logger.error("Chaos log write failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
#endif
