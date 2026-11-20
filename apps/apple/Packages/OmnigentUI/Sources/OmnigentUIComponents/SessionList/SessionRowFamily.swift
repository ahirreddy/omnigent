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

  /// How far the row sits in: a step when nested. A project's box, not an indent, marks its rows.
  var indent: CGFloat { isNested ? SessionFamilyMetrics.step : 0 }
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
  /// Each family's loaded members here, without unsent nested-agent drafts.
  private let memberCounts: [String: Int]
  /// Each family's head row title here.
  private let headTitles: [String: String]
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
    var familySizes: [String: Int] = [:]
    var memberCounts: [String: Int] = [:]
    var headTitles: [String: String] = [:]
    for row in rows {
      guard let family = row.family else { continue }
      familySizes[family.id, default: 0] += 1
      if state.nestedDrafts[row.id] == nil { memberCounts[family.id, default: 0] += 1 }
      if headTitles[family.id] == nil {
        heads.insert(row.id)
        headTitles[family.id] = row.title
      }
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
    self.memberCounts = memberCounts
    self.headTitles = headTitles
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

  /// The tooltip's family line (the web's `SessionFamilyDetail`): a head's "Nested sessions: 2"
  /// over its members loaded here, or a member's "Nested in: <head>".
  func detail(of session: SessionSummary) -> String? {
    guard let family = session.family, familySizes[family.id, default: 0] > 1 else { return nil }
    if heads.contains(session.id) {
      let nested = memberCounts[family.id, default: 1] - 1
      return nested > 0 ? "Nested sessions: \(nested)" : nil
    }
    return headTitles[family.id].map { "Nested in: \($0)" }
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
/// chevron, left empty on a row without one, so a head and its childless siblings line up; a
/// family's members sit one small step in. A project's rows don't indent: its box marks them.
enum SessionFamilyMetrics {
  /// The gutter: the chevron's square hit box.
  static let gutter: CGFloat = 12
  /// The chevron itself, at the gutter's leading edge.
  static let chevronWidth: CGFloat = 6
  /// Between the gutter and the row's icon.
  static let gutterSpacing = Theme.Spacing.extraSmall
  /// From a row's leading edge to its icon: the gutter and its spacing.
  static let lead = gutter + gutterSpacing
  /// One level of nesting, a family's members under its head.
  static let step = Theme.Spacing.small
  /// A session row's harness mark; a folder's icon takes the same width so its name lines up
  /// with the session titles.
  static let markWidth: CGFloat = 16
  /// A folder's rows that are no session (loading, No sessions, Show more): past the gutter, so
  /// their text starts at the icons of the folder's sessions.
  static let folderNoteIndent = lead
  /// Where a nested row's connector runs down, from its family's leading edge: under the middle
  /// of its head's chevron, clear of the member's own gutter and icon.
  static let connectorX = chevronWidth / 2
  /// Where the connector ends, just short of the nested row's icon.
  static let connectorEnd = step + lead - Theme.Spacing.extraSmall
  /// The connector's corner, where it turns toward the nested row.
  static let connectorRadius: CGFloat = 5
}

/// The connector beside a nested row, under its head's chevron: a line from the row's top that
/// turns toward the row at its mark's midline, and runs on to the row's bottom when another
/// member follows.
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
  /// A nested row's connector, laid on the row from its family's leading edge (before its
  /// step): down from the row's top to its mark's midline (its middle while the title is
  /// edited), and on down when it continues. Every row has the overlay, drawn only for a
  /// nested one, so a row is one view of one type and the list builds it only when it shows.
  func sessionFamilyConnector(rowHeight: CGFloat, family: SessionRowFamily) -> some View {
    overlayPreferenceValue(SessionMarkAnchor.self, alignment: .topLeading) { anchor in
      if case .nested(let continues) = family {
        SessionFamilyConnectorLine(anchor: anchor, rowHeight: rowHeight, continues: continues)
      }
    }
  }
}

/// A nested row's connector line, meeting the row's mark at `anchor`.
private struct SessionFamilyConnectorLine: View {
  let anchor: Anchor<CGRect>?
  let rowHeight: CGFloat
  let continues: Bool

  var body: some View {
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
