#if os(macOS)
  import AppKit
  import QuartzCore

  /// A row of the table transcript, whose key view loop leads on to the rows around it.
  ///
  /// AppKit leaves row views out of the window's key view loop: the table enters its first row,
  /// and each row's loop goes on past the table, so Tab missed the other rows' controls, such as
  /// a request card in the last row. Each row's loop here starts and ends in a
  /// ``TranscriptTableKeyLoopEdge``, which passes the keyboard on to the row above or below.
  final class TranscriptTableRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("transcript-row")

    let loopStart = TranscriptTableKeyLoopEdge(.start)
    let loopEnd = TranscriptTableKeyLoopEdge(.end)

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      identifier = Self.identifier
      // Added before any cell, the start comes first in the loop at the row's first corner.
      addSubview(loopStart)
      addSubview(loopEnd)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override func layout() {
      super.layout()
      // The loop runs top to bottom and leading to trailing: the row's corners bound it.
      let top = isFlipped ? bounds.minY : bounds.maxY - 1
      let bottom = isFlipped ? bounds.maxY - 1 : bounds.minY
      let start = NSRect(x: bounds.minX, y: top, width: 1, height: 1)
      let end = NSRect(x: bounds.maxX - 1, y: bottom, width: 1, height: 1)
      if loopStart.frame != start { loopStart.frame = start }
      if loopEnd.frame != end { loopEnd.frame = end }
    }

    /// The row's first view the keyboard can go to, in its key view loop.
    var firstKeyView: NSView? { keyViews.first }

    /// The row's last view the keyboard can go to.
    var lastKeyView: NSView? { keyViews.last }

    /// The views of the row's key view loop the keyboard can go to, in order. The edges, which
    /// only pass it on, are left out.
    private var keyViews: [NSView] {
      var found: [NSView] = []
      // AppKit declares the loop's links unowned(unsafe) and keeps them to views in the window.
      var view = unsafe nextKeyView
      for _ in 0..<Self.loopLimit {
        guard let current = view, current !== self, current.isDescendant(of: self) else { break }
        if !(current is TranscriptTableKeyLoopEdge), current.canBecomeKeyView {
          found.append(current)
        }
        view = unsafe current.nextKeyView
      }
      return found
    }

    /// The most views a loop is followed through.
    static let loopLimit = 500
  }

  /// Where a row's key view loop starts or ends. Tab and Shift-Tab land on it and it passes the
  /// keyboard on at once: from the end to the row below, from the start to the row above, past
  /// the transcript from the last or first row, and otherwise into its own row.
  final class TranscriptTableKeyLoopEdge: NSView {
    enum Edge {
      case start
      case end
    }

    let edge: Edge

    init(_ edge: Edge) {
      self.edge = edge
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    /// Only Tab and Shift-Tab bring the keyboard here.
    override var acceptsFirstResponder: Bool {
      // AppKit declares `window` unowned(unsafe); it is only read here.
      guard let window = unsafe window else { return false }
      return window.keyViewSelectionDirection != .directSelection
    }

    override func becomeFirstResponder() -> Bool {
      // AppKit declares `window` unowned(unsafe); it is only read here.
      guard let window = unsafe window, super.becomeFirstResponder() else { return false }
      let direction = window.keyViewSelectionDirection
      MainRunLoop.perform { [weak self] in
        MainActor.assumeIsolated { self?.passOn(direction) }
      }
      return true
    }

    /// Gives the keyboard to where Tab (`.selectingNext`) or Shift-Tab goes from this edge.
    private func passOn(_ direction: NSWindow.SelectionDirection) {
      // AppKit declares these unowned(unsafe); they are only read here.
      guard let window = unsafe window, window.firstResponder === self,
        let rowView = unsafe superview as? TranscriptTableRowView,
        let table = unsafe rowView.superview as? TranscriptTableNSView,
        TranscriptTableKeyLoopHops.take()
      else { return }
      let forward = direction != .selectingPrevious
      switch (edge, forward) {
      case (.end, true):
        if let next = table.keyView(after: rowView) {
          table.give(next)
        } else {
          table.leaveForward(from: self)
        }
      case (.start, false):
        if let previous = table.keyView(before: rowView) {
          table.give(previous)
        } else {
          window.selectKeyView(preceding: table)
        }
      case (.end, false):
        if let last = rowView.lastKeyView ?? table.keyView(before: rowView) {
          table.give(last)
        } else {
          window.selectKeyView(preceding: table)
        }
      case (.start, true):
        if let first = rowView.firstKeyView ?? table.keyView(after: rowView) {
          table.give(first)
        } else {
          table.leaveForward(from: self)
        }
      }
    }

    // It only marks the loop's edge: clicks go to the row.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  /// Bounds how often the transcript passes the keyboard on in a row: with nothing else in the
  /// window to go to, its edges would pass it around without end. A key press comes long after
  /// the last pass, and starts a new count.
  @MainActor
  enum TranscriptTableKeyLoopHops {
    static let limit = 8
    /// Passes closer together than this are one key press's.
    static let burst: CFTimeInterval = 0.02
    private static var last: CFTimeInterval = 0
    private static var hops = 0

    /// Whether the keyboard may be passed on once more.
    static func take() -> Bool {
      let now = CACurrentMediaTime()
      if now - last > burst { hops = 0 }
      last = now
      hops += 1
      return hops <= limit
    }
  }

  extension TranscriptTableNSView {
    /// The row views the table shows, top to bottom.
    var shownRowViews: [TranscriptTableRowView] {
      var rows: [(Int, TranscriptTableRowView)] = []
      enumerateAvailableRowViews { rowView, row in
        if let rowView = rowView as? TranscriptTableRowView { rows.append((row, rowView)) }
      }
      return rows.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The first view the keyboard can go to in the rows below `rowView`.
    func keyView(after rowView: TranscriptTableRowView) -> NSView? {
      let rows = shownRowViews
      guard let index = rows.firstIndex(where: { $0 === rowView }) else { return nil }
      return rows[(index + 1)...].lazy.compactMap(\.firstKeyView).first
    }

    /// The last view the keyboard can go to in the rows above `rowView`.
    func keyView(before rowView: TranscriptTableRowView) -> NSView? {
      let rows = shownRowViews
      guard let index = rows.firstIndex(where: { $0 === rowView }) else { return nil }
      return rows[..<index].reversed().lazy.compactMap(\.lastKeyView).first
    }

    /// Gives the keyboard to `view` in a row, scrolled into view as Tab's own move would.
    func give(_ view: NSView) {
      // AppKit declares `window` unowned(unsafe); it is only read here.
      guard let window = unsafe window, window.makeFirstResponder(view) else { return }
      view.scrollToVisible(view.bounds)
    }

    /// Tab past the rows from `edge`: on along AppKit's loop to the first view outside the
    /// transcript's scroll view, which the window then goes on from.
    func leaveForward(from edge: NSView) {
      // AppKit declares these unowned(unsafe); they are only read here.
      guard let window = unsafe window else { return }
      let transcript: NSView = enclosingScrollView ?? self
      var view = unsafe edge.nextKeyView
      for _ in 0..<TranscriptTableRowView.loopLimit {
        guard let current = view else { break }
        if !current.isDescendant(of: transcript) {
          if current.canBecomeKeyView {
            window.makeFirstResponder(current)
          } else {
            window.selectKeyView(following: current)
          }
          return
        }
        view = unsafe current.nextKeyView
      }
      window.selectKeyView(following: self)
    }
  }
#endif
