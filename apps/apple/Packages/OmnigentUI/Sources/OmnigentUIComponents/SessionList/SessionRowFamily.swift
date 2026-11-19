import SwiftUI

/// How a sidebar row sits in its session family, as the web's nested rows.
enum SessionRowFamily {
  /// On its own, or its family's only loaded member here.
  case standalone
  /// Nested under its family's head: one step in, with a connector from the head that runs on
  /// down when another member `continues` the family below it.
  case nested(continues: Bool)
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

  /// How far the row sits in: a step inside a project folder, and a step more when nested.
  func indent(inFolder: Bool) -> CGFloat {
    SessionFamilyMetrics.step * CGFloat((inFolder ? 1 : 0) + (isNested ? 1 : 0))
  }
}

/// A family's rows in one section or folder: which rows show, which head leads with a chevron
/// and which rows nest. A family's head is its first row here, as the rows are family-ordered.
struct SidebarFamilyLayout {
  /// The rows to draw: a collapsed family's head without the rest.
  let visible: [SessionSummary]
  private let scope: SidebarFamilyScope
  private let heads: Set<String>
  /// Nested rows with another member of their family right below them.
  private let continuing: Set<String>
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
    let visible = SidebarFamilies.visible(rows.prefix(listedCount), isCollapsed: isCollapsed)
    var continuing = Set<String>()
    for (row, next) in zip(visible, visible.dropFirst()) {
      if let family = row.family?.id, next.family?.id == family, !heads.contains(next.id) {
        continuing.insert(row.id)
      }
    }
    self.visible = visible
    self.scope = scope
    self.heads = heads
    self.continuing = continuing
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
    guard heads.contains(session.id) else {
      return .nested(continues: continuing.contains(session.id))
    }
    guard let setCollapsed else { return .standalone }
    let key = scope.key(family: family.id)
    let isExpanded = !isCollapsed(family.id)
    return .head(isExpanded: isExpanded, toggle: { setCollapsed(key, isExpanded) })
  }
}

/// The head row's chevron, a button of its own in the row's gutter: the row's click opens the
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
        .frame(width: SessionFamilyMetrics.chevronWidth)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .frame(
          width: SessionFamilyMetrics.gutter, height: SessionFamilyMetrics.gutter,
          alignment: .leading
        )
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

/// The sidebar's nesting grid. Every session row and project folder leads with a gutter for its
/// chevron, left empty on a row without one, so a head and its childless siblings line up; each
/// level of nesting is one step in, which puts a row's gutter under its parent's icon.
enum SessionFamilyMetrics {
  /// The gutter: the chevron's square hit box.
  static let gutter: CGFloat = 12
  /// The chevron itself, at the gutter's leading edge: where the Mac outline draws a folder's
  /// disclosure triangle, so every chevron sits on the same grid.
  static let chevronWidth: CGFloat = 6
  /// Between the gutter and the row's icon.
  static let gutterSpacing = Theme.Spacing.extraSmall
  /// One level of nesting: the gutter and its spacing.
  static let step = gutter + gutterSpacing
  /// A session row's harness mark; a folder's icon takes the same width so its name lines up
  /// with the session titles.
  static let markWidth: CGFloat = 16
  /// A folder's rows that are no session (loading, No sessions, Show more): a step in, past
  /// the gutter, so their text starts at the icons of the folder's sessions.
  static let folderNoteIndent = step * 2
  /// Where a nested row's connector runs down, from its gutter's leading edge: the gutter's
  /// middle, under its parent's icon.
  static let connectorX = gutter / 2
  /// Where the connector ends, just short of the nested row's icon.
  static let connectorEnd = step - Theme.Spacing.extraSmall
  /// The connector's corner, where it turns toward the nested row.
  static let connectorRadius: CGFloat = 5
}

/// The connector beside a nested row, in its gutter: a line from the row's top that turns toward
/// the row at its mark's midline, and runs on to the row's bottom when another member follows.
nonisolated struct SessionFamilyConnector: Shape {
  /// Where the line turns, from the top of its frame.
  let turn: CGFloat
  /// Whether the line runs on to the bottom, past the turn.
  let continues: Bool
  /// The turn's corner.
  let cornerRadius: CGFloat

  func path(in rect: CGRect) -> Path {
    let turnY = min(max(rect.minY + turn, rect.minY), rect.maxY)
    let radius = min(cornerRadius, rect.width, turnY - rect.minY)
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.minX, y: turnY - radius))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + radius, y: turnY), control: CGPoint(x: rect.minX, y: turnY))
    path.addLine(to: CGPoint(x: rect.maxX, y: turnY))
    if continues {
      path.move(to: CGPoint(x: rect.minX, y: turnY - radius))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    }
    return path
  }
}

/// Where a row's mark is, for its connector to meet: its harness icon, else its title.
struct SessionMarkAnchor: PreferenceKey {
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

  /// A nested row's connector, down its gutter from the row's top to its mark's midline (its
  /// middle while the title is edited), and on down when it `continues`.
  func sessionFamilyConnector(rowHeight: CGFloat, continues: Bool) -> some View {
    overlayPreferenceValue(SessionMarkAnchor.self, alignment: .topLeading) { anchor in
      GeometryReader { proxy in
        let midline = anchor.map { proxy[$0].midY } ?? proxy.size.height / 2
        // The list centers a short row's content; the connector reaches the row's edges.
        let beyond = max(0, (rowHeight - proxy.size.height) / 2)
        SessionFamilyConnector(
          turn: midline + beyond, continues: continues,
          cornerRadius: SessionFamilyMetrics.connectorRadius
        )
        .stroke(Theme.mutedText.opacity(0.4), lineWidth: 1)
        .frame(
          width: SessionFamilyMetrics.connectorEnd - SessionFamilyMetrics.connectorX,
          height: proxy.size.height + beyond * 2
        )
        .offset(x: SessionFamilyMetrics.connectorX, y: -beyond)
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }
}
