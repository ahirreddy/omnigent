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
  /// accent; the Mac source list already draws them neutral (and dims them with the window).
  /// - Returns: The row.
  func neutralSidebarIcon() -> some View {
    #if os(iOS)
      foregroundStyle(ThemeColor.primary)
    #else
      self
    #endif
  }
}

private struct SidebarSelectionModifier: ViewModifier {
  let isSelected: Bool

  func body(content: Content) -> some View {
    content
      #if os(macOS)
        .background { SystemSelectionHighlightRemover().accessibilityHidden(true) }
      #endif
      .listRowBackground(SidebarSelectionBackground(isSelected: isSelected))
  }
}

/// The selected row's fill: the softened theme selection while the window is active, a neutral
/// fill while it is not (as the system's own unemphasized selection).
struct SidebarSelectionBackground: View {
  let isSelected: Bool
  #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    private let cornerRadius = Theme.Radius.small
    private let inset = Theme.Spacing.medium
  #else
    // The system's own sidebar selection shape: the full row, rounder.
    private let appearsActive = true
    private let cornerRadius = Theme.Radius.large
    private let inset: CGFloat = 0
  #endif
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    if isSelected {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(fill)
        .overlay {
          if contrast == .increased {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
              .strokeBorder(ThemeColor.border)
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
