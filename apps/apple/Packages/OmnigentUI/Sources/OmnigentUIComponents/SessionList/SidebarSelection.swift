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
  /// - Parameters:
  ///   - isSelected: Whether this row is the list's selection.
  ///   - indent: How far the row sits in, nested in its family; its fill starts there.
  ///   - box: Its part of its project's box, drawn behind it; `nil` outside a project.
  /// - Returns: The row.
  func sidebarSelection(
    _ isSelected: Bool, indent: CGFloat = 0, box: SidebarBoxPart? = nil
  ) -> some View {
    modifier(SidebarSelectionModifier(isSelected: isSelected, indent: indent, box: box))
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
  let indent: CGFloat
  let box: SidebarBoxPart?
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
        .background { SidebarTableStyle().accessibilityHidden(true) }
        .onHover { isHovered = $0 }
      #endif
      .listRowBackground(
        ZStack {
          if let box { SidebarProjectBox(part: box) }
          SidebarSelectionBackground(isSelected: isSelected, isHovered: isHovered, box: box)
            .padding(.leading, indent)
        }
        .animation(reduceMotion ? nil : Theme.Motion.feedback, value: isHovered))
  }
}

/// The selected row's fill: the softened theme selection while the window is active, a neutral
/// fill while it is not (as the system's own unemphasized selection). Hover uses the same shape
/// and layers over the selection, so a hovered selected row reads as both.
struct SidebarSelectionBackground: View {
  let isSelected: Bool
  var isHovered = false
  /// Its row's part of a project's box: the fill keeps the box's padding inside it.
  var box: SidebarBoxPart?
  #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    private static let cornerRadius = Theme.Radius.small
    private static let inset = Theme.Spacing.medium
  #else
    // The system's own sidebar selection shape: the full row, rounder.
    private let appearsActive = true
    private static let cornerRadius = Theme.Radius.large
    private static let inset: CGFloat = 0
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
        .padding(.top, edge(box?.opens == true))
        .padding(.bottom, edge(box?.closes == true))
    }
  }

  /// Inside a box, the corners follow the box's and the fill keeps its padding from each edge.
  private var cornerRadius: CGFloat {
    box == nil ? Self.cornerRadius : SidebarBoxMetrics.radius - SidebarBoxMetrics.padding
  }

  private var inset: CGFloat {
    box == nil ? Self.inset : SidebarBoxMetrics.inset + SidebarBoxMetrics.padding
  }

  /// Above or below the fill: past the box's own gap where the box ends there.
  private func edge(_ boxEnds: Bool) -> CGFloat {
    boxEnds ? SidebarBoxMetrics.gap + SidebarBoxMetrics.padding : 1
  }

  private var fill: ThemeColor {
    appearsActive ? Theme.selection : ThemeColor.primary.opacity(0.08)
  }
}

#if os(macOS)

  /// Turns off the enclosing table's own selection highlight and its indent of a folder's rows.
  /// It sits in a row, so the table is one of its ancestors; the style is set again whenever
  /// the row moves, since SwiftUI may rebuild the table.
  private struct SidebarTableStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> TableStyleView { TableStyleView() }

    func updateNSView(_ view: TableStyleView, context: Context) {
      view.styleTable()
    }

    final class TableStyleView: NSView {
      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        styleTable()
      }

      override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        styleTable()
      }

      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      func styleTable() {
        // `superview` is `unowned(unsafe)` in AppKit. Each step reads it on the main thread
        // while this view is in the hierarchy, so every ancestor is alive.
        var ancestor = unsafe superview
        while let view = ancestor, !(view is NSTableView) { ancestor = unsafe view.superview }
        guard let table = ancestor as? NSTableView else { return }
        if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
        guard let outline = table as? NSOutlineView else { return }
        // The rows draw their own indent (`SessionFamilyMetrics`).
        if outline.indentationPerLevel != 0 { outline.indentationPerLevel = 0 }
        Self.placeMisplacedRows(of: outline)
      }

      /// A row laid out while the list still had SwiftUI's indent keeps it, 9 points in: a new
      /// window's first rows, now and then. A column width change places every row's cells again.
      private static func placeMisplacedRows(of outline: NSOutlineView) {
        var misplaced = false
        outline.enumerateAvailableRowViews { rowView, row in
          guard let cell = rowView.view(atColumn: 0) as? NSView else { return }
          let place = rowView.convert(outline.frameOfCell(atColumn: 0, row: row), from: outline)
          if abs(cell.frame.minX - place.minX) > 0.5 { misplaced = true }
        }
        guard misplaced, let column = outline.tableColumns.first else { return }
        column.width -= 1
        column.width += 1
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
