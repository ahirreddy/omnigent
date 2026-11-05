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
    @State private var selection: TranscriptSelection?
    @State private var clearRequest = 0

    /// Room the popup needs above a selection before it goes below it instead.
    private static let headroom: CGFloat = 40

    func body(content: Content) -> some View {
      content
        .background {
          SelectionWatcher(clearRequest: clearRequest) { next in
            if next != selection { selection = next }
          }
        }
        .onScrollGeometryChange(for: CGFloat.self) {
          $0.contentOffset.y
        } action: { _, _ in
          if selection != nil { selection = nil }
        }
        .overlay(alignment: .topLeading) {
          if let selection, let reply {
            let below = selection.rect.minY < Self.headroom
            let gap = Theme.Spacing.small
            buttons(selection.text, reply: reply)
              .fixedSize()
              .alignmentGuide(.leading) { $0[HorizontalAlignment.center] - selection.rect.midX }
              .alignmentGuide(.top) { size in
                below
                  ? -(selection.rect.maxY + gap) : size[.bottom] - (selection.rect.minY - gap)
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

  /// Reports the selection in the transcript's selectable text. SwiftUI's selectable `Text` is an
  /// `NSTextField` that selects through the window's field editor, so a selection is the field
  /// editor of a non-editable field, inside this view's bounds.
  private struct SelectionWatcher: NSViewRepresentable {
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
        view.clearSelection()
      }
    }

    static func dismantleNSView(_ view: WatcherView, coordinator: ()) {
      view.stop()
    }

    final class WatcherView: NSView {
      var changed: (@MainActor (TranscriptSelection?) -> Void)?
      var clearRequest = 0
      private var monitor: Any?

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
      }

      func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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
      private func bounds(of range: NSRange, in editor: NSTextView) -> CGRect? {
        // Both are AppKit `unowned(unsafe)` references the editor keeps alive while it shows.
        guard let layout = unsafe editor.layoutManager, let container = unsafe editor.textContainer
        else {
          return nil
        }
        // No actual range is asked for, so the out-pointer is nil.
        let glyphs = unsafe layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = editor.textContainerOrigin
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
          .offsetBy(dx: origin.x, dy: origin.y)
        return convert(editor.convert(rect, to: nil), from: nil)
      }
    }
  }
#endif

extension View {
  /// The selection popup over the transcript on the Mac; `reply` `nil` hides it.
  func transcriptSelectionPopup(
    reply: (@MainActor (String) -> Void)?, ask: (@MainActor (String) -> Void)?
  ) -> some View {
    #if os(macOS)
      modifier(TranscriptSelectionPopup(reply: reply, ask: ask))
    #else
      self
    #endif
  }
}
