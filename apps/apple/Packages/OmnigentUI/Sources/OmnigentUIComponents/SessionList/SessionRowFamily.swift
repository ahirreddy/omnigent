import SwiftUI

/// How a sidebar row sits in its session family, as the web's nested rows.
enum SessionRowFamily {
  /// On its own, or its family's only loaded member here.
  case standalone
  /// Nested under its family's head: indented, with an elbow from the head.
  case nested
  /// The family's head, led by the chevron that collapses and expands the rest.
  case head(isExpanded: Bool, toggle: @MainActor () -> Void)

  /// Nested under its family's head.
  var isNested: Bool {
    if case .nested = self { return true }
    return false
  }

  /// Whether `session`'s row pins and moves only with its family: nested here, or nested under
  /// another representative on the server.
  func movesWithFamily(_ session: SessionSummary) -> Bool {
    isNested || session.isNestedMember
  }
}

/// A family's rows in one section or folder: which rows show, which head leads with a chevron
/// and which rows nest. A family's head is its first row here, as the rows are family-ordered.
struct SidebarFamilyLayout {
  /// The rows to draw: a collapsed family's head without the rest.
  let visible: [SessionSummary]
  private let scope: SidebarFamilyScope
  private let heads: Set<String>
  private let familySizes: [String: Int]
  private let isCollapsed: (String) -> Bool
  private let setCollapsed: (@MainActor (String, Bool) -> Void)?

  /// - Parameters:
  ///   - rows: Every row of the section or folder, family-ordered, hidden ones included.
  ///   - listedCount: How many of `rows` its page lists; all by default.
  ///   - scope: The section's or folder's ``SidebarFamilyScope``.
  ///   - state: The sidebar, with its collapsed families.
  ///   - setCollapsed: Collapses or expands a family by key; `nil` shows no chevrons.
  init(
    rows: [SessionSummary], listedCount: Int = .max, scope: SidebarFamilyScope,
    state: SidebarViewState,
    setCollapsed: (@MainActor (String, Bool) -> Void)?
  ) {
    var heads = Set<String>()
    var seen = Set<String>()
    var familySizes: [String: Int] = [:]
    for row in rows {
      guard let family = row.family else { continue }
      familySizes[family.id, default: 0] += 1
      if seen.insert(family.id).inserted { heads.insert(row.id) }
    }
    let isCollapsed = { (family: String) in state.isFamilyCollapsed(family, in: scope) }
    self.visible = SidebarFamilies.visible(rows.prefix(listedCount), isCollapsed: isCollapsed)
    self.scope = scope
    self.heads = heads
    self.familySizes = familySizes
    self.isCollapsed = isCollapsed
    self.setCollapsed = setCollapsed
  }

  /// How `session` sits in its family here: a chevron leads a head only when the family has
  /// more than one loaded row here.
  func family(of session: SessionSummary) -> SessionRowFamily {
    guard let family = session.family, familySizes[family.id, default: 0] > 1 else {
      return .standalone
    }
    guard heads.contains(session.id) else { return .nested }
    guard let setCollapsed else { return .standalone }
    let key = scope.key(family: family.id)
    let isExpanded = !isCollapsed(family.id)
    return .head(isExpanded: isExpanded, toggle: { setCollapsed(key, isExpanded) })
  }
}

/// The head row's chevron, a button of its own beside the row: the row's click opens the
/// session, this one shows or hides the family's other members.
struct SessionFamilyChevron: View {
  let sessionID: String
  let isExpanded: Bool
  let toggle: @MainActor () -> Void

  var body: some View {
    let label = isExpanded ? "Collapse session family" : "Expand session family"
    Button(action: toggle) {
      Image(systemName: "chevron.right")
        .font(.system(size: 9, weight: .semibold))
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .frame(width: SessionFamilyMetrics.chevronWidth, height: SessionFamilyMetrics.chevronWidth)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(Theme.mutedText)
    .help(label)
    .accessibilityLabel(label)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .accessibilityIdentifier("session-family-toggle-\(sessionID)")
  }
}

/// A family's row metrics, the web's adapted to the native row.
enum SessionFamilyMetrics {
  /// The chevron's square hit box at a head row's leading edge.
  static let chevronWidth: CGFloat = 16
  /// Between the chevron and the head row's content.
  static let chevronSpacing = Theme.Spacing.extraSmall
  /// A nested row's extra leading inset: its content starts right of its head's.
  static let nestedIndent: CGFloat = 32
  /// The elbow's width, from the chevron's trailing edge toward the nested row.
  static let elbowWidth: CGFloat = 8
  /// The elbow's bottom-left corner.
  static let elbowRadius: CGFloat = 6
}

/// The decorative elbow beside a nested row: a line from the row's top that turns toward the
/// row at its title's midline.
nonisolated struct SessionFamilyElbow: Shape {
  /// The bottom-left corner.
  let cornerRadius: CGFloat

  func path(in rect: CGRect) -> Path {
    let radius = min(cornerRadius, rect.width, rect.height)
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + radius, y: rect.maxY),
      control: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    return path
  }
}

/// Where a row's title is, for its elbow to meet.
struct SessionTitleAnchor: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil

  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}

extension View {
  /// Drags `payload` from this row; `nil` makes it no drag source.
  @ViewBuilder
  func sidebarDraggable(_ payload: String?) -> some View {
    if let payload {
      draggable(payload)
    } else {
      self
    }
  }

  /// A nested row: indented, with the elbow from the row's top to its title's midline (or its
  /// middle while the title is edited).
  func sessionFamilyNest(rowHeight: CGFloat) -> some View {
    padding(.leading, SessionFamilyMetrics.nestedIndent)
      .overlayPreferenceValue(SessionTitleAnchor.self, alignment: .topLeading) { anchor in
        GeometryReader { proxy in
          let midline = anchor.map { proxy[$0].midY } ?? proxy.size.height / 2
          // The list centers a short row's content; the elbow reaches up to the row's top.
          let above = max(0, (rowHeight - proxy.size.height) / 2)
          SessionFamilyElbow(cornerRadius: SessionFamilyMetrics.elbowRadius)
            .stroke(Theme.mutedText.opacity(0.4), lineWidth: 1)
            .frame(width: SessionFamilyMetrics.elbowWidth, height: midline + above)
            .offset(x: SessionFamilyMetrics.chevronWidth, y: -above)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
  }
}
