import Foundation

/// What the table transcript's top row shows: the history's state, and the banners above the
/// first message.
nonisolated struct TranscriptTableHeader: Hashable, Sendable {
  enum History: Hashable, Sendable {
    case none
    case offersOlder
    case loading
  }

  var history: History = .none
  /// The newer session this one was superseded by.
  var superseded: EventSection?
  /// The CLI style's plan, which scrolls with the rows.
  var plan: EventSection?
  /// The conversation, while it has no rows to show (its empty or loading state).
  var empty: ConversationViewState?
}

/// What the table transcript's last row shows: requests, the working line and failures.
nonisolated struct TranscriptTableFooter: Hashable, Sendable {
  struct Working: Hashable, Sendable {
    var isBlocked: Bool
    var startedAt: Date?
  }

  var isCLI = false
  /// The unanswered requests, as a conversation with no rows.
  var decisions: ConversationViewState?
  var startup: EventSection?
  var working: Working?
  var turnFailure: String?
  var sessionError: String?
}

/// One row's content: what its cell renders.
nonisolated enum TranscriptTableContent: Hashable, Sendable {
  case header(TranscriptTableHeader)
  case segment(SegmentEntry)
  case block(CLIBlockEntry)
  case footer(TranscriptTableFooter)
}

/// The kinds of row a cell is reused for, and estimated heights are calibrated by.
nonisolated enum TranscriptTableRowKind: String, Hashable, Sendable, CaseIterable {
  case header, footer, userMessage, answer, tools, activity, worked, cliFooter
}

/// One table row: a transcript row (a chat segment or a CLI block), or the header or footer.
nonisolated struct TranscriptTableRow: Hashable, Sendable, Identifiable {
  static let headerID = "transcript-table-header"
  static let footerID = "transcript-table-footer"

  let id: String
  let content: TranscriptTableContent

  init(_ content: TranscriptTableContent) {
    self.content = content
    id =
      switch content {
      case .header: Self.headerID
      case .footer: Self.footerID
      case .segment(let entry): entry.id
      case .block(let entry): entry.id
      }
  }

  var kind: TranscriptTableRowKind {
    switch content {
    case .header: .header
    case .footer: .footer
    case .segment(let entry): Self.kind(of: entry.segment)
    case .block(let entry):
      switch entry.block {
      case .segment(let segment): Self.kind(of: segment)
      case .footer: .cliFooter
      }
    }
  }

  /// Whether the row is a user's message, which opening frames at the top.
  var isUserMessage: Bool { kind == .userMessage }

  private static func kind(of segment: TurnSegment) -> TranscriptTableRowKind {
    switch segment {
    case .worked: .worked
    case .item(.message(let row)): row.role == .user ? .userMessage : .answer
    case .item(.tools): .tools
    case .item(.activity): .activity
    }
  }
}

extension TranscriptTableRow {
  /// The transcript's rows in one style's layout.
  enum Layout {
    case chat([SegmentEntry])
    case cli([CLIBlockEntry])
  }

  /// The table's rows for `state`: the header, the rows in order, then the footer.
  /// - Parameters:
  ///   - state: The conversation, with the rows the list shows.
  ///   - layout: Its segments in the chat style, or its blocks in the CLI style.
  ///   - offersOlder: The host can load older history.
  /// - Returns: One row per segment or block, between the header and the footer.
  static func rows(
    for state: ConversationViewState, layout: Layout, offersOlder: Bool
  ) -> [Self] {
    let body: [Self]
    let isCLI: Bool
    switch layout {
    case .chat(let entries):
      body = entries.map { Self(.segment($0)) }
      isCLI = false
    case .cli(let blocks):
      body = blocks.map { Self(.block($0)) }
      isCLI = true
    }
    let header = header(for: state, isCLI: isCLI, isEmpty: body.isEmpty, offersOlder)
    return [Self(.header(header))] + body + [Self(.footer(footer(for: state, isCLI: isCLI)))]
  }

  static func header(
    for state: ConversationViewState, isCLI: Bool, isEmpty: Bool, _ offersOlder: Bool
  ) -> TranscriptTableHeader {
    var header = TranscriptTableHeader()
    if state.isLoadingHistory {
      header.history = .loading
    } else if state.hasMoreHistory, offersOlder {
      header.history = .offersOlder
    }
    if let superseded = state.section("superseded"), let target = superseded.sessionId,
      target != state.header.id
    {
      header.superseded = superseded
    }
    if isCLI, let todos = state.section("todos"), !todos.details.isEmpty { header.plan = todos }
    if isEmpty { header.empty = state }
    return header
  }

  static func footer(for state: ConversationViewState, isCLI: Bool) -> TranscriptTableFooter {
    var footer = TranscriptTableFooter(isCLI: isCLI)
    if state.decisions.contains(where: { !$0.answered }) {
      // Only what the request cards read, so a streamed delta leaves the footer alone.
      footer.decisions = ConversationViewState(
        header: state.header, decisions: state.decisions, decisionPhases: state.decisionPhases)
    }
    if !isCLI { footer.startup = state.section("startup") }
    if state.header.status == .running, !(state.rows.last?.isStreaming ?? false) {
      footer.working = .init(
        isBlocked: !state.pendingDecisions.isEmpty, startedAt: TurnElapsed.start(in: state))
    }
    let failures = TranscriptFailures(state)
    footer.turnFailure = failures.turnFailure
    footer.sessionError = failures.sessionError
    return footer
  }
}

/// How the table's rows changed between two updates: one run of rows replaced (rows added at
/// either end, a page of history above, a sent row's echo), and the rows kept whose content
/// changed (a streamed answer, a decoration that moved).
nonisolated struct TranscriptTableChange: Equatable, Sendable {
  /// Old indices of the rows taken out.
  var removed: Range<Int>
  /// New indices of the rows put in their place.
  var inserted: Range<Int>
  /// New indices of kept rows whose content changed.
  var changed: [Int]

  var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && changed.isEmpty }

  /// The change from `old` to `new`, matched by id from both ends.
  static func between(_ old: [TranscriptTableRow], _ new: [TranscriptTableRow]) -> Self {
    let shorter = min(old.count, new.count)
    var prefix = 0
    while prefix < shorter, old[prefix].id == new[prefix].id { prefix += 1 }
    var suffix = 0
    while suffix < shorter - prefix,
      old[old.count - 1 - suffix].id == new[new.count - 1 - suffix].id
    {
      suffix += 1
    }
    var changed: [Int] = []
    for index in 0..<prefix where old[index].content != new[index].content {
      changed.append(index)
    }
    for offset in 0..<suffix {
      let oldIndex = old.count - suffix + offset
      let newIndex = new.count - suffix + offset
      if old[oldIndex].content != new[newIndex].content { changed.append(newIndex) }
    }
    return Self(
      removed: prefix..<(old.count - suffix), inserted: prefix..<(new.count - suffix),
      changed: changed)
  }
}

/// Row heights by row id, each for the content version and width it was measured at. A height
/// measured for an older version or another width stands in, as the best guess, until the row
/// is measured again; a row never measured gets an estimate from its content, scaled by how
/// the estimates of its kind compared with the heights measured so far.
nonisolated struct TranscriptRowHeights: Sendable {
  struct Measured: Equatable, Sendable {
    var version: Int
    var width: CGFloat
    var height: CGFloat
  }

  private var measured: [String: Measured] = [:]
  /// Per kind, the measured and estimated heights added up, for scaling new estimates.
  private var calibration: [TranscriptTableRowKind: (measured: Double, estimated: Double)] = [:]

  /// The height measured for `id`, whatever its version and width.
  func measurement(of id: String) -> Measured? { measured[id] }

  /// Whether `id` was measured at `version` and `width`.
  func isCurrent(_ id: String, version: Int, width: CGFloat) -> Bool {
    guard let entry = measured[id] else { return false }
    return entry.version == version && abs(entry.width - width) < 0.5
  }

  /// The height to lay `row` out at: measured if it ever was, else estimated.
  func height(of row: TranscriptTableRow, width: CGFloat) -> CGFloat {
    if let entry = measured[row.id] { return entry.height }
    return estimate(row, width: width)
  }

  /// An estimate for a row not measured yet, scaled by its kind's measurements.
  func estimate(_ row: TranscriptTableRow, width: CGFloat) -> CGFloat {
    let raw = Self.rawEstimate(row, width: width)
    guard let scale = calibration[row.kind], scale.estimated > 0 else { return raw }
    return max(1, (raw * CGFloat(scale.measured / scale.estimated)).rounded())
  }

  /// Records a measured height.
  mutating func record(
    _ height: CGFloat, for row: TranscriptTableRow, version: Int, width: CGFloat
  ) {
    if measured[row.id] == nil {
      var scale = calibration[row.kind] ?? (0, 0)
      scale.measured += Double(height)
      scale.estimated += Double(Self.rawEstimate(row, width: width))
      calibration[row.kind] = scale
    }
    measured[row.id] = Measured(version: version, width: width, height: height)
  }

  /// Drops the heights of rows that are gone.
  mutating func keep(only ids: Set<String>) {
    measured = measured.filter { ids.contains($0.key) }
  }

  /// A guess from the row's text: lines at an average character width, plus its chrome.
  static func rawEstimate(_ row: TranscriptTableRow, width: CGFloat) -> CGFloat {
    let charactersPerLine = max(20, (min(width, 760) - 64) / 7.5)
    func textHeight(_ text: String) -> CGFloat {
      var lines: CGFloat = 0
      for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
        lines += max(1, (CGFloat(paragraph.count) / charactersPerLine).rounded(.up))
      }
      return lines * 20
    }
    switch row.content {
    case .header: return 24
    case .footer: return 24
    case .segment(let entry): return segmentEstimate(entry.segment, textHeight)
    case .block(let entry):
      switch entry.block {
      case .segment(let segment): return segmentEstimate(segment, textHeight)
      case .footer: return 32
      }
    }
  }

  private static func segmentEstimate(
    _ segment: TurnSegment, _ textHeight: (String) -> CGFloat
  ) -> CGFloat {
    switch segment {
    case .worked: return 44
    case .item(.message(let row)): return textHeight(row.text) + (row.role == .user ? 48 : 56)
    case .item(.tools(_, let entries)): return 36 * CGFloat(max(1, entries.count)) + 24
    case .item(.activity): return 48
    }
  }
}

/// The table's rows with their content versions and heights: what the table asks for each row,
/// kept apart from AppKit so tests can drive it.
nonisolated struct TranscriptTableModel: Sendable {
  private(set) var rows: [TranscriptTableRow] = []
  private(set) var ids: [String] = []
  private var indexByID: [String: Int] = [:]
  /// Each row's content version, raised when the content under its id changes.
  private var versions: [String: Int] = [:]
  private(set) var heights = TranscriptRowHeights()
  /// The heights the table was last given, by row id.
  private var provided: [String: CGFloat] = [:]
  /// The width rows are laid out at.
  private(set) var width: CGFloat = 0

  /// Takes the rows of an update.
  /// - Returns: How they changed.
  mutating func replaceRows(_ new: [TranscriptTableRow]) -> TranscriptTableChange {
    let change = TranscriptTableChange.between(rows, new)
    guard !change.isEmpty else { return change }
    for index in change.changed { versions[new[index].id, default: 0] += 1 }
    // A row taken out and put back in the same change keeps its version unless it changed.
    let replaced = Dictionary(
      rows[change.removed].map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first })
    for row in new[change.inserted] {
      if let old = replaced[row.id] {
        if old != row.content { versions[row.id, default: 0] += 1 }
      } else {
        versions[row.id] = 0
        provided[row.id] = nil
      }
    }
    rows = new
    ids = new.map(\.id)
    indexByID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    if !change.removed.isEmpty {
      let kept = Set(ids)
      heights.keep(only: kept)
      versions = versions.filter { kept.contains($0.key) }
      provided = provided.filter { kept.contains($0.key) }
    }
    return change
  }

  /// Lays rows out at `width`.
  /// - Returns: Whether the width changed.
  mutating func setWidth(_ width: CGFloat) -> Bool {
    guard abs(width - self.width) >= 0.5 else { return false }
    self.width = width
    return true
  }

  /// Every row is measured again, its old height standing in until then: the text's size changed
  /// (Dynamic Type), which changes every row's height without changing its content.
  mutating func invalidateHeights() {
    for id in ids { versions[id, default: 0] += 1 }
  }

  func index(of id: String) -> Int? { indexByID[id] }

  func version(at index: Int) -> Int { versions[rows[index].id] ?? 0 }

  /// The height row `index` is laid out at.
  func height(at index: Int) -> CGFloat { heights.height(of: rows[index], width: width) }

  /// The height for the table to lay row `index` out at, remembered as what it was given.
  mutating func provideHeight(at index: Int) -> CGFloat {
    let height = height(at: index)
    provided[rows[index].id] = height
    return height
  }

  /// Whether row `index` needs measuring: never measured, or for other content or width.
  func needsMeasure(at index: Int) -> Bool {
    !heights.isCurrent(rows[index].id, version: version(at: index), width: width)
  }

  /// Records row `index`'s measured height.
  /// - Returns: Whether the table was given another height for it, so it has to ask again.
  @discardableResult
  mutating func record(_ height: CGFloat, at index: Int) -> Bool {
    let row = rows[index]
    heights.record(height, for: row, version: version(at: index), width: width)
    guard let given = provided[row.id] else { return false }
    return abs(given - height) >= 0.5
  }
}
