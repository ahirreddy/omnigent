#if os(macOS)
  import AppKit
  import SwiftUI

  /// The table transcript's AppKit side: a scroll view over a view-based table with one row per
  /// transcript row. Cells are reused hosting views; heights are measured once per row, content
  /// version and width, and estimated until then. A scroll frame moves the clip view and, now
  /// and then, fills a reused cell with a row coming into view.
  @MainActor
  final class TranscriptTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// Where a shown row lands.
    enum Placement {
      case top
      case center
    }

    /// The row under the viewport's top and how far into it the top is.
    struct ReadingAnchor: Equatable {
      var id: String
      var offset: CGFloat
    }

    /// How close to the top, in points, reading starts loading older history.
    static let olderHistoryReach: CGFloat = 400
    /// How close to the end counts as at the bottom.
    static let bottomReach: CGFloat = Theme.Spacing.extraLarge + 16
    /// Of a viewport, how far ahead of a scroll rows are measured before they show.
    static let lookahead: CGFloat = 0.75
    /// The main thread time one scroll frame may spend measuring rows not yet in view.
    static let lookaheadBudget: CFTimeInterval = 0.003
    /// The main thread time one idle pass may spend measuring rows away from the viewport.
    static let prefetchBudget: CFTimeInterval = 0.004
    /// How long after the last move idle measuring starts.
    static let prefetchDelay: TimeInterval = 0.3
    /// How long after its last step a wheel scroll counts as ended.
    static let wheelEnd: TimeInterval = 0.2

    /// The views, made when the list first shows: SwiftUI makes a controller with each
    /// update of the view that holds it, and keeps only the first.
    private(set) lazy var scrollView = makeScrollView()
    private(set) lazy var tableView = TranscriptTableNSView()
    let environment = TranscriptTableEnvironment()
    lazy var clipView = TranscriptTableClipView()
    lazy var column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
    var model = TranscriptTableModel()
    var pool = TranscriptTableCellPool()
    /// One cell per kind measures rows away from the viewport, whose cells are not kept.
    var measuringCells: [TranscriptTableRowKind: TranscriptTableCell] = [:]

    /// The follow rules (``TranscriptFollow``).
    var follow = TranscriptFollow() {
      didSet { if follow.pill != oldValue.pill { schedulePill() } }
    }
    /// Shows the follow rules' pill; the transcript sets it. Called back at the run loop, as
    /// the rules change inside SwiftUI's updates too.
    var showPill: (TranscriptFollow.Pill) -> Void = { _ in }
    /// The row ids in order and those on screen, when the rows on screen change; called back
    /// at the run loop.
    var visibleRowsChanged: ([String], Set<String>) -> Void = { _, _ in }
    var awaitsPill = false
    var awaitsVisibleReport = false

    var state: ConversationViewState?
    var actions = ConversationActions()
    var isCLI = false
    var insets = NSEdgeInsets()
    var sessionID: String?
    var needsFraming = false
    var pendingShow: (id: String, placement: Placement)?
    var olderRequested = false
    var historyReads = 0
    var isShown = true

    var isAdjusting = false
    var isMeasuring = false
    var isLiveScrolling = false
    var isWheeling = false
    var wheelSteps = 0
    var visibleRange = 0..<0
    var pendingCells: [ObjectIdentifier: TranscriptTableCell] = [:]
    var awaitsRemeasure = false
    var prefetchGeneration = 0
    var prefetchCursor: (above: Int, below: Int)?

    /// Counts for tests and the performance log.
    var measurements = 0
    var cellsMade = 0

    func makeScrollView() -> NSScrollView {
      let scrollView = TranscriptTableScrollView()
      scrollView.owner = self
      clipView.owner = self
      clipView.drawsBackground = false
      scrollView.contentView = clipView
      scrollView.drawsBackground = false
      scrollView.hasVerticalScroller = true
      scrollView.hasHorizontalScroller = false
      scrollView.autohidesScrollers = true
      scrollView.automaticallyAdjustsContentInsets = false
      tableView.headerView = nil
      tableView.style = .plain
      tableView.selectionHighlightStyle = .none
      tableView.intercellSpacing = .zero
      tableView.backgroundColor = .clear
      tableView.gridStyleMask = []
      tableView.allowsColumnReordering = false
      tableView.allowsColumnResizing = false
      tableView.allowsEmptySelection = true
      tableView.focusRingType = .none
      tableView.refusesFirstResponder = true
      tableView.usesAutomaticRowHeights = false
      tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
      column.resizingMask = .autoresizingMask
      tableView.addTableColumn(column)
      tableView.dataSource = self
      tableView.delegate = self
      scrollView.documentView = tableView
      let center = NotificationCenter.default
      clipView.postsBoundsChangedNotifications = true
      center.addObserver(
        self, selector: #selector(clipBoundsChanged),
        name: NSView.boundsDidChangeNotification, object: clipView)
      center.addObserver(
        self, selector: #selector(liveScrollStarted),
        name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
      center.addObserver(
        self, selector: #selector(liveScrollEnded),
        name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
      return scrollView
    }

    // MARK: Updates

    /// Takes a SwiftUI update: the rows, the conversation and the environment the cells render in.
    func update(
      rows: [TranscriptTableRow], state: ConversationViewState, actions: ConversationActions,
      isCLI: Bool, environment values: EnvironmentValues
    ) {
      environment.values = values
      self.actions = actions
      self.isCLI = isCLI
      let previous = self.state
      self.state = state
      if state.header.id != sessionID {
        sessionID = state.header.id
        follow.reset()
        needsFraming = true
        pendingShow = nil
        olderRequested = false
      }
      if state.historyReads != historyReads || !state.isLoadingHistory {
        if state.historyReads != historyReads { olderRequested = false }
        historyReads = state.historyReads
      }
      _ = scrollView
      syncWidth()
      let anchor = readingAnchor()
      let change = model.replaceRows(rows)
      if !change.isEmpty { apply(change) }
      if frameIfReady() {
        // Opened: framed at its latest turn.
      } else if !change.isEmpty {
        let isNewOutput = previous?.revision != state.revision
        if isNewOutput ? follow.contentChanged() : follow.layoutGrew() {
          pinBottom()
        } else {
          restore(anchor)
        }
      }
      if let pendingShow, model.index(of: pendingShow.id) != nil {
        show(pendingShow.id, at: pendingShow.placement)
      }
      reportVisibleRows()
      if !change.inserted.isEmpty || !change.removed.isEmpty { schedulePrefetch() }
    }

    func schedulePill() {
      guard !awaitsPill else { return }
      awaitsPill = true
      MainRunLoop.perform { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.awaitsPill = false
          self.showPill(self.follow.pill)
        }
      }
    }

    /// Whether the transcript has rows besides its header and footer.
    var hasRows: Bool { model.rows.count > 2 }

    /// Frames a session's latest turn once its rows are there and the viewport has its size.
    /// - Returns: Whether it framed now.
    func frameIfReady() -> Bool {
      guard needsFraming, hasRows, state?.isHydrating == false, model.width > 0,
        clipView.bounds.height > 0
      else { return false }
      needsFraming = false
      frameLatestTurn()
      return true
    }

    /// Puts a change into the table without animation; kept rows on screen show their new
    /// content and are measured now, in this pass.
    func apply(_ change: TranscriptTableChange) {
      withoutAnimation {
        tableView.beginUpdates()
        if !change.removed.isEmpty {
          tableView.removeRows(at: IndexSet(integersIn: change.removed), withAnimation: [])
        }
        if !change.inserted.isEmpty {
          tableView.insertRows(at: IndexSet(integersIn: change.inserted), withAnimation: [])
        }
        tableView.endUpdates()
      }
      if !change.removed.isEmpty { pool.keep(only: Set(model.ids)) }
      // Rows above moved the indices the idle measuring had reached.
      if !change.removed.isEmpty || !change.inserted.isEmpty { prefetchCursor = nil }
      var noted = IndexSet()
      for index in change.changed {
        guard let cell = realizedCell(at: index) else { continue }
        if measure(index, with: cell) { noted.insert(index) }
      }
      noteHeights(noted)
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      guard model.rows.indices.contains(row) else { return 1 }
      return max(1, model.provideHeight(at: row))
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
      guard model.rows.indices.contains(row) else { return nil }
      let cell = keptCell(for: model.rows[row])
      if model.needsMeasure(at: row) {
        // A row the lookahead missed: measured now, its height given to the table next pass.
        if measure(row, with: cell) { scheduleRemeasure(cell) }
      } else {
        cell.show(model.rows[row], version: model.version(at: row), width: model.width)
      }
      return cell
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
      guard rowView.numberOfColumns > 0,
        let cell = rowView.view(atColumn: 0) as? TranscriptTableCell
      else { return }
      pool.park(cell)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
  }
#endif
