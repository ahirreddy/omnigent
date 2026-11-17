#if os(macOS)
  import AppKit
  import Observation
  import SwiftUI

  /// The transcript's environment, handed to the table's cells on each update: each cell is a
  /// hosting view of its own, outside the transcript's SwiftUI tree.
  @MainActor
  @Observable
  final class TranscriptTableEnvironment {
    var values: EnvironmentValues?
  }

  /// What one cell renders: a row at the table's width, at its ideal height, in the transcript's
  /// environment. The row content is SwiftUI's for now; a cell's view can take another kind of
  /// content later without the table changing.
  struct TranscriptTableCellRoot: View {
    var row: TranscriptTableRow?
    var width: CGFloat
    let environment: TranscriptTableEnvironment

    var body: some View {
      let values = environment.values
      TranscriptTableRowContent(row: row)
        // A reused cell starts the next row's view state afresh.
        .id(row?.id)
        .frame(width: max(0, width))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: .top)
        .transformEnvironment(\.self) { own in
          if let values { own = values }
        }
    }
  }

  /// A row's SwiftUI content, as the lazy stack lays it out: in the transcript's column, with
  /// the stack's spacing below it.
  struct TranscriptTableRowContent: View {
    let row: TranscriptTableRow?
    @Environment(\.transcriptFocus) private var focus

    var body: some View {
      switch row?.content {
      case .segment(let entry):
        TurnSegmentView(entry: entry)
          .equatable()
          .background { if focus?.flashedRowID == entry.id { MessageFlash() } }
          .transcriptStackColumn()
          .padding(.bottom, Theme.Spacing.row)
      case .block(let entry):
        CLIBlockView(block: entry.block, decorations: entry.decorations)
          .equatable()
          .overlay { if focus?.flashedRowID == entry.id { MessageFlash(isBand: true) } }
          .transcriptStackColumn()
          .padding(.bottom, CLIMetrics.blockGap)
      case .header(let header):
        TranscriptTableHeaderView(header: header)
      case .footer(let footer):
        TranscriptTableFooterView(footer: footer)
      case nil:
        EmptyView()
      }
    }
  }

  /// The top row: older history, and the banners and empty state above the first message.
  struct TranscriptTableHeaderView: View {
    let header: TranscriptTableHeader
    @Environment(\.conversationActions) private var actions
    @Environment(\.transcriptAppearance) private var appearance

    var body: some View {
      VStack(alignment: .leading, spacing: spacing) {
        switch header.history {
        case .loading:
          HStack {
            Spacer()
            ProgressView("Loading earlier messages\u{2026}").controlSize(.small)
            Spacer()
          }
          .accessibilityIdentifier("history-loading")
        case .offersOlder:
          HStack {
            Spacer()
            Button("Load earlier messages", systemImage: "clock.arrow.circlepath") {
              actions.loadOlder?()
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("load-older-messages")
            Spacer()
          }
        case .none:
          EmptyView()
        }
        if let plan = header.plan { PlanCard(section: plan).transcriptColumn() }
        if let superseded = header.superseded, let target = superseded.sessionId {
          banner(SupersededBanner(section: superseded, target: target))
        }
        if let empty = header.empty { banner(EmptyTranscriptView(state: empty)) }
      }
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .padding(.top, Theme.Spacing.extraLarge)
      .padding(.bottom, hasContent ? spacing : 0)
      .transcriptStackColumn()
    }

    private var spacing: CGFloat { appearance.isCLI ? CLIMetrics.blockGap : Theme.Spacing.row }

    private var hasContent: Bool {
      header.history != .none || header.plan != nil || header.superseded != nil
        || header.empty != nil
    }

    /// CLI rows set their own column, so the CLI's banners take the chat's.
    @ViewBuilder private func banner(_ view: some View) -> some View {
      if appearance.isCLI { view.transcriptColumn() } else { view }
    }
  }

  /// The last row: requests, the working line, and the turn's or session's failure.
  struct TranscriptTableFooterView: View {
    let footer: TranscriptTableFooter
    @Environment(\.conversationActions) private var actions

    var body: some View {
      VStack(alignment: .leading, spacing: spacing) {
        if let decisions = footer.decisions {
          banner(InlineDecisions(state: decisions, actions: actions))
        }
        if let startup = footer.startup { StartupLine(section: startup) }
        if let working = footer.working {
          if footer.isCLI {
            CLIWorkingLine(isBlocked: working.isBlocked, startedAt: working.startedAt)
          } else {
            WorkingIndicator(isBlocked: working.isBlocked, startedAt: working.startedAt)
          }
        }
        if let failure = footer.turnFailure {
          banner(FailureBanner(message: failure, resume: actions.resume))
        }
        if let error = footer.sessionError {
          banner(ErrorBanner(message: error, dismiss: actions.dismissError, retry: actions.retry))
        }
      }
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .padding(.bottom, Theme.Spacing.extraLarge)
      .transcriptStackColumn()
    }

    private var spacing: CGFloat { footer.isCLI ? CLIMetrics.blockGap : Theme.Spacing.row }

    @ViewBuilder private func banner(_ view: some View) -> some View {
      if footer.isCLI { view.transcriptColumn() } else { view }
    }
  }

  /// What a cell shows, by row id, content version and width.
  struct TranscriptTableShown: Equatable {
    var id: String
    var version: Int
    var width: CGFloat
  }

  /// The kinds of cell the pool reuses: rows hosted in SwiftUI, and settled messages drawn as
  /// TextKit text in AppKit (``TranscriptTableTextCell``), each by row kind.
  enum TranscriptTableCellKind: Hashable {
    case hosted(TranscriptTableRowKind)
    case text(TranscriptTableRowKind)
  }

  /// A table cell: it shows one row at a width and reports when its content's ideal size
  /// changes (a fold opening, an image arriving) instead of asking Auto Layout.
  @MainActor
  protocol TranscriptTableCell: NSView {
    var shown: TranscriptTableShown? { get }
    var kind: TranscriptTableCellKind? { get }
    /// Told when the content's ideal size may have changed.
    var idealSizeChanged: ((any TranscriptTableCell) -> Void)? { get set }
    /// Shows `row`, unless the cell shows that version of it at `width` already.
    func show(_ row: TranscriptTableRow, version: Int, width: CGFloat)
    /// The content's height at the width it shows, laid out now if it has to be.
    var idealHeight: CGFloat { get }
    /// Takes no size report until the frame now being made is displayed.
    func settle()
  }

  /// A cell hosting a row's SwiftUI view.
  final class TranscriptTableHostingCell: NSHostingView<TranscriptTableCellRoot>,
    TranscriptTableCell
  {
    private(set) var shown: TranscriptTableShown?
    private(set) var kind: TranscriptTableCellKind?
    var idealSizeChanged: ((any TranscriptTableCell) -> Void)?

    /// A cell for the table: no window bridging, no safe area, sized by its row.
    static func make(environment: TranscriptTableEnvironment) -> TranscriptTableHostingCell {
      let cell = TranscriptTableHostingCell(
        rootView: TranscriptTableCellRoot(row: nil, width: 0, environment: environment))
      cell.sizingOptions = [.intrinsicContentSize]
      cell.safeAreaRegions = []
      cell.sceneBridgingOptions = []
      return cell
    }

    func show(_ row: TranscriptTableRow, version: Int, width: CGFloat) {
      let next = TranscriptTableShown(id: row.id, version: version, width: width)
      guard next != shown else { return }
      shown = next
      kind = .hosted(row.kind)
      rootView = TranscriptTableCellRoot(
        row: row, width: width, environment: rootView.environment)
      settle()
    }

    var idealHeight: CGFloat { intrinsicContentSize.height.rounded(.up) }

    /// The cell's new content has not been laid out and drawn yet. Its height is known for that
    /// content and width, so the report that follows its first layout is not a change.
    private var isSettling = false

    func settle() {
      guard !isSettling else { return }
      isSettling = true
      MainRunLoop.performAfterDisplay { [weak self] in
        MainActor.assumeIsolated { self?.isSettling = false }
      }
    }

    /// Reports the change; the table, not Auto Layout, sizes the cell.
    override func invalidateIntrinsicContentSize() {
      guard !isSettling else { return }
      idealSizeChanged?(self)
    }
  }

  /// Cells not in the table, kept by the row they last showed so a row that comes back shows
  /// without rendering again, and handed to rows of the same kind once the oldest are evicted.
  @MainActor
  struct TranscriptTableCellPool {
    /// How many parked cells keep their row.
    var parkedLimit = 48
    /// How many spare cells of each kind are kept beyond those.
    var spareLimit = 4

    private var parked: [String: any TranscriptTableCell] = [:]
    /// Parked row ids, oldest first.
    private var order: [String] = []
    private var spares: [TranscriptTableCellKind: [any TranscriptTableCell]] = [:]

    var parkedCount: Int { parked.count }

    /// A cell of `kind` for row `id`: the one that last showed it, else a spare of its kind,
    /// else, once the pool is full, the oldest parked cell of its kind; `nil` for a new one.
    mutating func take(id: String, kind: TranscriptTableCellKind) -> (any TranscriptTableCell)? {
      if let cell = parked[id] {
        parked[id] = nil
        order.removeAll { $0 == id }
        // A row whose kind changed (it settled, or the style did) takes another cell.
        guard cell.kind == kind else {
          spare(cell)
          return take(id: id, kind: kind)
        }
        return cell
      }
      if let cell = spares[kind]?.popLast() { return cell }
      guard parked.count >= parkedLimit,
        let oldest = order.first(where: { parked[$0]?.kind == kind }),
        let cell = parked.removeValue(forKey: oldest)
      else { return nil }
      order.removeAll { $0 == oldest }
      return cell
    }

    /// Keeps a cell that left the table, under the row it shows.
    mutating func park(_ cell: any TranscriptTableCell) {
      guard let id = cell.shown?.id else {
        spare(cell)
        return
      }
      if let other = parked[id], other !== cell { spare(other) }
      parked[id] = cell
      order.removeAll { $0 == id }
      order.append(id)
      while order.count > parkedLimit {
        let oldest = order.removeFirst()
        if let cell = parked.removeValue(forKey: oldest) { spare(cell) }
      }
    }

    /// Lets go of the rows that are gone: their cells become spares.
    mutating func keep(only ids: Set<String>) {
      for id in order where !ids.contains(id) {
        if let cell = parked.removeValue(forKey: id) { spare(cell) }
      }
      order.removeAll { !ids.contains($0) }
    }

    private mutating func spare(_ cell: any TranscriptTableCell) {
      guard let kind = cell.kind else { return }
      if spares[kind, default: []].count < spareLimit { spares[kind, default: []].append(cell) }
    }
  }
#endif
