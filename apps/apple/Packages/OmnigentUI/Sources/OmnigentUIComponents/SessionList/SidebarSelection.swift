import SwiftUI

#if os(macOS)
  import AppKit
#endif

extension View {
  /// Marks a selectable sidebar row. The system draws list selection in the saturated accent
  /// (or a flat gray), so the selected row gets the softened theme selection behind it instead
  /// (the web's `--sidebar-active`); on macOS the table's own highlight is also turned off.
  /// Selection itself stays the list's: arrow keys, type-select, VoiceOver's "selected", swipe
  /// actions and the Delete command work as before.
  /// - Parameter isSelected: Whether this row is the list's selection.
  /// - Returns: The row.
  func sidebarSelection(_ isSelected: Bool) -> some View {
    modifier(SidebarSelectionModifier(isSelected: isSelected))
  }

  /// A sidebar row's icon in the text color. The iOS sidebar style tints icons with the system
  /// accent, inside the label, so the tint itself is set; the Mac source list already draws them
  /// neutral (and dims them with the window).
  /// - Returns: The row.
  func neutralSidebarIcon() -> some View {
    #if os(iOS)
      foregroundStyle(ThemeColor.primary).tint(ThemeColor.primary)
    #else
      self
    #endif
  }
}

private struct SidebarSelectionModifier: ViewModifier {
  let isSelected: Bool
  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      #if os(iOS)
        // A selected row in a focused list gets a prominent background and white labels; the
        // softened fill behind it needs the standard label colors.
        .foregroundStyle(.primary)
        .environment(\.backgroundProminence, .standard)
      #endif
      #if os(macOS)
        .background { SystemSelectionHighlightRemover().accessibilityHidden(true) }
        .onHover { isHovered = $0 }
      #endif
      .listRowBackground(
        SidebarSelectionBackground(isSelected: isSelected, isHovered: isHovered)
          .animation(reduceMotion ? nil : Theme.Motion.feedback, value: isHovered))
  }
}

/// The selected row's fill: the softened theme selection while the window is active, a neutral
/// fill while it is not (as the system's own unemphasized selection). Hover uses the same shape
/// and layers over the selection, so a hovered selected row reads as both.
struct SidebarSelectionBackground: View {
  let isSelected: Bool
  var isHovered = false
  #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    private var cornerRadius: CGFloat { Theme.Radius.small }
    private var inset: CGFloat { Theme.Spacing.medium }
  #else
    // The system's own sidebar selection shape: the full row, rounder.
    private let appearsActive = true
    private let cornerRadius = Theme.Radius.large
    private let inset: CGFloat = 0
  #endif
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    if isSelected || isHovered {
      let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      shape
        .fill(isSelected ? AnyShapeStyle(fill) : AnyShapeStyle(.clear))
        .overlay { shape.fill(ThemeColor.hover.opacity(isHovered ? 1 : 0)) }
        .overlay {
          if isSelected, contrast == .increased {
            shape.strokeBorder(ThemeColor.border)
          }
        }
        .padding(.horizontal, inset)
        .padding(.vertical, 1)
    }
  }

  private var fill: ThemeColor {
    appearsActive ? Theme.selection : ThemeColor.primary.opacity(0.08)
  }
}

#if os(macOS)

  /// Turns off the enclosing table's own selection highlight. It sits in a row, so the table is
  /// one of its ancestors; the style is set again whenever the row moves, since SwiftUI may
  /// rebuild the table.
  private struct SystemSelectionHighlightRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> HighlightRemoverView { HighlightRemoverView() }

    func updateNSView(_ view: HighlightRemoverView, context: Context) {
      view.removeHighlight()
    }

    final class HighlightRemoverView: NSView {
      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeHighlight()
      }

      override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        removeHighlight()
      }

      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      func removeHighlight() {
        // `superview` is `unowned(unsafe)` in AppKit. Each step reads it on the main thread
        // while this view is in the hierarchy, so every ancestor is alive.
        var ancestor = unsafe superview
        while let view = ancestor, !(view is NSTableView) { ancestor = unsafe view.superview }
        guard let table = ancestor as? NSTableView, table.selectionHighlightStyle != .none else {
          return
        }
        table.selectionHighlightStyle = .none
      }
    }
  }
#endif

/// The session whose title is edited in place, and the text.
struct SidebarInlineEdit {
  var session: SessionSummary?
  var text = ""

  mutating func begin(_ session: SessionSummary) {
    text = session.title
    self.session = session
  }

  /// The field's hooks for the edit in `edit`.
  static func field(
    _ edit: Binding<Self>, rename: ((SessionSummary, String) -> Void)?
  ) -> InlineRename {
    InlineRename(
      text: edit.text,
      commit: {
        if let (session, title) = edit.wrappedValue.finish() { rename?(session, title) }
      },
      cancel: { edit.wrappedValue.session = nil })
  }

  /// Ends the edit. Returns the session and its new title, trimmed; `nil` when there's nothing to
  /// save (no edit, or a title that is empty, unchanged or too long).
  mutating func finish() -> (session: SessionSummary, title: String)? {
    guard let session else { return nil }
    self.session = nil
    let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, title != session.title, title.count <= SessionDialogs.maxTitleLength
    else { return nil }
    return (session, title)
  }
}
