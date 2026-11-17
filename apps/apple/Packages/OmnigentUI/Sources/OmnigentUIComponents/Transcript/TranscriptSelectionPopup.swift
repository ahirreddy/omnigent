import SwiftUI

#if os(macOS)
  import AppKit

  /// Text selected in the transcript, and its bounds in the transcript's coordinates.
  struct TranscriptSelection: Equatable {
    /// The selected text, trimmed.
    var text: String
    /// Where it is.
    var rect: CGRect
  }

  /// The web's selection popup: selecting transcript text shows "Reply", which quotes it in the
  /// composer, and "Ask in side chat" above the selection. Scrolling or clearing the selection
  /// hides it.
  struct TranscriptSelectionPopup: ViewModifier {
    let reply: (@MainActor (String) -> Void)?
    let ask: (@MainActor (String) -> Void)?
    /// The table transcript's scrolls, which no SwiftUI scroll view reports.
    var feed: TranscriptScrollFeed?
    @State private var selection: TranscriptSelection?
    @State private var clearRequest = 0

    func body(content: Content) -> some View {
      feed?.selectionMoved = { if selection != nil { selection = nil } }
      return
        content
        .background {
          SelectionWatcher(clearRequest: clearRequest) { next in
            if next != selection { selection = next }
          }
        }
        .onScrollGeometryChange(for: CGFloat.self) {
          $0.contentOffset.y
        } action: { _, _ in
          if feed == nil, selection != nil { selection = nil }
        }
        .overlay {
          // A layout places the popup; the overlay ignores alignment guides on a view in this `if`.
          if let selection, let reply {
            SelectionPopupPlacement(selection: selection.rect, gap: Theme.Spacing.small) {
              buttons(selection.text, reply: reply)
            }
          }
        }
    }

    private func buttons(_ text: String, reply: @escaping @MainActor (String) -> Void)
      -> some View
    {
      HStack(spacing: Theme.Spacing.extraSmall) {
        button("Reply", symbol: "arrowshape.turn.up.left", id: "selection-reply") {
          reply(text)
        }
        if let ask {
          button(
            "Ask in side chat", symbol: "bubble.left.and.bubble.right", id: "selection-side-chat"
          ) { ask(text) }
        }
      }
      .padding(Theme.Spacing.tiny)
      .glassSurface(in: Capsule(), isInteractive: true)
      .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private func button(
      _ title: String, symbol: String, id: String, action: @escaping @MainActor () -> Void
    ) -> some View {
      Button {
        action()
        clearRequest += 1
      } label: {
        Label(title, systemImage: symbol)
          .font(.callout)
          .padding(.horizontal, Theme.Spacing.small)
          .padding(.vertical, Theme.Spacing.extraSmall)
          .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .hoverHighlight(cornerRadius: Theme.Radius.small)
      .accessibilityIdentifier(id)
    }
  }

  /// Centers the popup just above the selection, or just below it without room above, and keeps
  /// it inside the transcript's width.
  struct SelectionPopupPlacement: Layout {
    let selection: CGRect
    /// The space between the popup and the selection, and the transcript's edges.
    let gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
      proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
      in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
      for popup in subviews {
        let size = popup.sizeThatFits(.unspecified)
        let above = selection.minY - gap - size.height
        let top = above >= 0 ? above : selection.maxY + gap
        let widest = max(gap, bounds.width - gap - size.width)
        let leading = min(max(selection.midX - size.width / 2, gap), widest)
        popup.place(
          at: CGPoint(x: bounds.minX + leading, y: bounds.minY + top), proposal: .init(size))
      }
    }
  }

  /// Reports the selection in the transcript's selectable text. SwiftUI's selectable `Text` is an
  /// `NSTextField` that selects through the window's field editor, so a selection is the field
  /// editor of a non-editable field, inside this view's bounds.
  struct SelectionWatcher: NSViewRepresentable {
    let clearRequest: Int
    let changed: @MainActor (TranscriptSelection?) -> Void

    func makeNSView(context: Context) -> WatcherView {
      let view = WatcherView()
      view.changed = changed
      view.clearRequest = clearRequest
      return view
    }

    func updateNSView(_ view: WatcherView, context: Context) {
      view.changed = changed
      if view.clearRequest != clearRequest {
        view.clearRequest = clearRequest
        // Clearing writes the popup's state, which SwiftUI drops during a view update.
        Task { @MainActor in view.clearSelection() }
      }
    }

    static func dismantleNSView(_ view: WatcherView, coordinator: ()) {
      view.stop()
    }

    final class WatcherView: NSView {
      var changed: (@MainActor (TranscriptSelection?) -> Void)?
      var clearRequest = 0
      private var monitor: Any?
      private var selectionObserver: (any NSObjectProtocol)?

      override var isFlipped: Bool { true }

      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        // AppKit declares `window` unowned(unsafe); it is only compared here, never retained.
        guard unsafe window != nil else { return }
        // A drag selects inside the text view's own tracking loop, which the mouse-down
        // starts and the mouse-up ends, so the selection is read once that event is handled.
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .keyUp]
        monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
          if let self, unsafe event.window === self.window {
            Task { @MainActor [weak self] in self?.refresh() }
          }
          return event
        }
        // A drag or Shift-click changes the selection inside that tracking loop, which no
        // monitor sees; the field editor's selection change moves the popup with it.
        selectionObserver = NotificationCenter.default.addObserver(
          forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main
        ) { [weak self] note in
          let sender = note.object.map { ObjectIdentifier($0 as AnyObject) }
          MainActor.assumeIsolated {
            // Only the text view selecting in this window, which `refresh` checks further.
            guard let self, let window = unsafe self.window,
              let responder = window.firstResponder, ObjectIdentifier(responder) == sender
            else { return }
            Task { @MainActor [weak self] in self?.refresh() }
          }
        }
      }

      func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil
      }

      /// Ends the selection after the popup acted on it.
      func clearSelection() {
        if let window = unsafe window, selectionEditor(in: window) != nil {
          window.makeFirstResponder(nil)
        }
        changed?(nil)
      }

      private func selectionEditor(in window: NSWindow) -> NSTextView? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
          !editor.isEditable, let field = editor.delegate as? NSTextField, !field.isEditable
        else { return nil }
        return editor
      }

      private func refresh() {
        guard let window = unsafe window, let editor = selectionEditor(in: window) else {
          changed?(nil)
          return
        }
        let range = editor.selectedRange()
        let text = Range(range, in: editor.string).map { String(editor.string[$0]) }?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty, let rect = bounds(of: range, in: editor) else {
          changed?(nil)
          return
        }
        // Selections elsewhere in the window (the inspector, a sheet) are not the transcript's.
        changed?(bounds.intersects(rect) ? TranscriptSelection(text: text, rect: rect) : nil)
      }

      /// The selected range's bounds in this view's coordinates.
      func bounds(of range: NSRange, in editor: NSTextView) -> CGRect? {
        guard let rect = Self.containerBounds(of: range, in: editor) else { return nil }
        let origin = editor.textContainerOrigin
        return convert(
          editor.convert(rect.offsetBy(dx: origin.x, dy: origin.y), to: nil), from: nil)
      }

      /// The range's bounds in the editor's text container. A TextKit 2 editor's `layoutManager`
      /// would turn the window's field editor into TextKit 1, which drops exact line heights.
      static func containerBounds(of range: NSRange, in editor: NSTextView) -> CGRect? {
        if let layout = editor.textLayoutManager {
          return containerBounds(of: range, in: layout)
        }
        // Both are AppKit `unowned(unsafe)` references the editor keeps alive while it shows.
        guard let layout = unsafe editor.layoutManager, let container = unsafe editor.textContainer
        else {
          return nil
        }
        // No actual range is asked for, so the out-pointer is nil.
        let glyphs = unsafe layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container)
      }

      /// The union of TextKit 2's selection segments for `range`; `nil` past the text's end.
      private static func containerBounds(of range: NSRange, in layout: NSTextLayoutManager)
        -> CGRect?
      {
        guard let content = layout.textContentManager,
          let start = content.location(content.documentRange.location, offsetBy: range.location),
          let end = content.location(start, offsetBy: range.length),
          let textRange = NSTextRange(location: start, end: end)
        else {
          return nil
        }
        layout.ensureLayout(for: textRange)
        var union: CGRect?
        layout.enumerateTextSegments(in: textRange, type: .selection) { _, frame, _, _ in
          union = union?.union(frame) ?? frame
          return true
        }
        return union
      }
    }
  }
#endif

extension View {
  /// The selection popup over the transcript on the Mac; `reply` `nil` hides it. `feed` gives
  /// it the table transcript's scrolls.
  func transcriptSelectionPopup(
    reply: (@MainActor (String) -> Void)?, ask: (@MainActor (String) -> Void)?,
    feed: TranscriptScrollFeed? = nil
  ) -> some View {
    #if os(macOS)
      modifier(TranscriptSelectionPopup(reply: reply, ask: ask, feed: feed))
    #else
      self
    #endif
  }
}
