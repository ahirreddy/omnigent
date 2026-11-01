import SwiftUI

#if os(macOS)
  import AppKit
#endif

extension View {
  /// Marks a selectable sidebar row. On macOS the source list draws its selection in the system
  /// accent and ignores `.tint`, so the list's own highlight is turned off and the selected row
  /// gets the theme accent behind it instead (the web's `--sidebar-active`, accent at 12%).
  /// Selection itself stays the list's: arrow keys, type-select, VoiceOver's "selected" and the
  /// Delete command work as before. Elsewhere the system selection already follows `.tint`.
  /// - Parameter isSelected: Whether this row is the list's selection.
  /// - Returns: The row.
  func sidebarSelection(_ isSelected: Bool) -> some View {
    #if os(macOS)
      modifier(SidebarSelectionModifier(isSelected: isSelected))
    #else
      self
    #endif
  }
}

#if os(macOS)
  private struct SidebarSelectionModifier: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
      content
        .background { SystemSelectionHighlightRemover().accessibilityHidden(true) }
        .listRowBackground(SidebarSelectionBackground(isSelected: isSelected))
    }
  }

  /// The selected row's fill: the theme accent while the window is active, a neutral fill while
  /// it is not (as the system's own unemphasized selection).
  private struct SidebarSelectionBackground: View {
    let isSelected: Bool
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
      if isSelected {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(fill)
          .padding(.horizontal, 10)
          .padding(.vertical, 1)
      }
    }

    private var fill: ThemeColor {
      guard appearsActive else { return ThemeColor.primary.opacity(0.08) }
      return Theme.accent.opacity(colorScheme == .dark ? 0.24 : 0.14)
    }
  }

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
