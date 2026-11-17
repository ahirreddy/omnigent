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
    /// How many viewports above and below idle measuring reaches.
    static let prefetchReach: CGFloat = 5
    /// How many viewports away idle measuring keeps the cells it measured in.
    static let keptReach: CGFloat = 1.5
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
    var pool = TranscriptTableCellPool<any TranscriptTableCell>()
    /// One cell per kind measures rows away from the viewport, whose cells are not kept.
    var measuringCells: [TranscriptTableCellKind: any TranscriptTableCell] = [:]
    /// Measures the blocks only SwiftUI draws in messages away from the viewport.
    var measuringBlock: TranscriptTableBlockView?
    /// Measures the parts beside the text that SwiftUI draws, in messages away from the viewport.
    var measuringAccessory: TranscriptTableAccessoryView?
    /// The style settled messages draw in as text cells.
    lazy var textStyle = TranscriptTableTextStyle(environment: environment)
    /// Each row's text-cell message by content version, `nil` for a row hosted in SwiftUI.
    var textMessages: [String: (version: Int, message: TranscriptTableTextMessage?)] = [:]
    /// Answers handed to the prewarm, by row id and version.
    var prewarmed: [String: Int] = [:]
    /// The CLI rows drawn as text cells.
    lazy var cli = TranscriptTableCLIState(environment: environment, textStyle: textStyle)
    /// Which rows beyond settled messages draw in AppKit cells.
    let cellStyle = TranscriptTableCellStyle.launchValue
    /// How SwiftUI rows are sized.
    let hostingStyle = TranscriptTableHostingStyle.launchValue
    /// The Worked folds and long prompts the reader opened or closed, in ``disclosures``.
    lazy var folds = TranscriptTableFolds(disclosures: disclosures)
    var awaitsEnvironment = false
    /// Follows VoiceOver turning on or off, which shows or hides the text cells' actions.
    var voiceOverWatch: NSKeyValueObservation?
    /// Follows the window's linked-message flash for the text cells (``watchFlash()``).
    var awaitsFlash = false

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
    var cursorRectsPaused = false
    /// The answer idle measuring waits for the prewarm to lay out, and since when.
    var prewarmAwaited: (id: String, since: CFTimeInterval)?
    /// Where a width change under way keeps the reader, taken before the viewport resized.
    var resizeAnchor: WidthAnchor?
    /// Where the reader was when the tab hid, for the width it takes when it shows.
    var hiddenAnchor: WidthAnchor?
    /// A short number for this transcript in loop reports.
    private(set) lazy var probeTag = Int(
      UInt(bitPattern: ObjectIdentifier(self).hashValue) % 10_000)

    /// Jumps animate (motion on, not reduced); the transcript sets it.
    var animatesJumps = false
    var activeJump: TranscriptTableJump?
    var jumpTimer: Timer?
    /// Where Jump to top's paging stands.
    let position = TranscriptReadingPosition()
    /// The first row the source has read, ahead of the rows the list shows; the transcript sets
    /// it, with the rows' pacing that Jump to top holds and releases.
    var sourceTopRow: () -> String? = { nil }
    var holdRows: () -> Void = {}
    var releaseRows: () -> Void = {}
    /// The scrolls the pills and the selection popup over the table follow.
    let scrollFeed = TranscriptScrollFeed()
    /// The viewport over the last row, for its inline request cards.
    let tableViewport = TranscriptTableViewport()
    /// The folds' open choices, which outlive the cells that show them.
    let disclosures = TranscriptDisclosures()
    /// An assistive client reads the window: rows not laid out are read through stand-ins.
    var isReadByAssistiveClient = false
    var rowElements: [String: TranscriptRowElement] = [:]

    var isAdjusting = false
    var isMeasuring = false
    var isLiveScrolling = false
    var isWheeling = false
    var wheelSteps = 0
    var visibleRange = 0..<0
    var pendingCells: [ObjectIdentifier: any TranscriptTableCell] = [:]
    var awaitsRemeasure = false
    var prefetchGeneration = 0
    var prefetchCursor: (above: Int, below: Int)?

    /// Rows measured during a live resize, at a snapped text width.
    var measuredWhileResizing: Set<String> = []

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
      // Holding the keyboard for a row that left, the table takes no typing for its rows.
      tableView.allowsTypeSelect = false
      tableView.owner = self
      disclosures.changed = { [weak self] in self?.foldChanged() }
      // The keyboard goes through the rows' controls, not the scroll bar.
      scrollView.verticalScroller?.refusesFirstResponder = true
      scrollView.setAccessibilityLabel("Transcript")
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

    /// Takes a SwiftUI update: the rows and the conversation, and the environment the cells
    /// render in until the environment's own feed hands it over.
    func update(
      rows: [TranscriptTableRow], state: ConversationViewState, actions: ConversationActions,
      isCLI: Bool, environment values: EnvironmentValues
    ) {
      if environment.values == nil { environment.values = values }
      syncTextStyle()
      watchVoiceOver()
      watchFlash()
      self.actions = actions
      self.isCLI = isCLI
      let previous = self.state
      self.state = state
      if state.header.id != sessionID { sessionOpened(state.header.id) }
      historyChanged(state)
      _ = scrollView
      // A hidden tab's rows keep their width until it shows.
      if isShown { syncWidth() }
      let topAnchor = readingAnchor()
      let pageAnchor = readingAnchor(belowHeader: true)
      let change = model.replaceRows(rows)
      // A page landing under the header keeps the reader on the rows they were reading.
      let anchor =
        change.inserted.lowerBound == 1 && !change.inserted.isEmpty ? pageAnchor : topAnchor
      if !change.isEmpty {
        probe("transcript rows changed", "\(change.removed) -> \(change.inserted), \(follow)")
        apply(change)
      }
      if frameIfReady() {
        // Opened: framed at its latest turn.
      } else if !change.isEmpty {
        keepReader(anchor, isNewOutput: previous?.revision != state.revision)
      }
      if previous?.header.id == state.header.id, previous?.rows.first?.id != state.rows.first?.id {
        firstRowChanged()
      }
      if let pendingShow, model.index(of: pendingShow.id) != nil {
        show(pendingShow.id, at: pendingShow.placement)
      }
      reportVisibleRows()
      reportFooterViewport()
      if !change.inserted.isEmpty || !change.removed.isEmpty {
        schedulePrefetch()
        if isReadByAssistiveClient { rowsChangedForAssistiveClient() }
      }
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
      showChanged(change.changed)
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
      let cell = keptCell(at: row)
      if model.needsMeasure(at: row) {
        // A row the lookahead missed: measured now, its height given to the table next pass.
        if measure(row, with: cell) { scheduleRemeasure(cell) }
      } else {
        cell.show(model.rows[row], version: model.version(at: row), width: model.width)
        // An AppKit cell knows its height without a layout: one that differs from what the
        // row was measured at (in another cell, from sizes) is told to the table next pass.
        if cell.kind?.isHosted == false, abs(cell.idealHeight - model.height(at: row)) >= 0.5 {
          scheduleRemeasure(cell)
        }
      }
      // Its row's height is known: going into the window and laying out there changes nothing.
      cell.settle()
      return cell
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
      guard rowView.numberOfColumns > 0,
        let cell = rowView.view(atColumn: 0) as? any TranscriptTableCell
      else { return }
      // Off screen, a drawn run's bitmap counts only against the rasters' cache.
      (cell as? TranscriptTableTextCell)?.releaseBitmaps()
      (cell as? TranscriptTableCLICell)?.releaseBitmaps()
      pool.park(cell)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
      // A cell measured away from the window lays out its views now, so the frame that shows
      // it has its text.
      rowView.layoutSubtreeIfNeeded()
    }
  }

  extension TranscriptTableController {
    // MARK: Sessions and history

    /// A read of older history ended: the reader near the top may ask for the next.
    func historyChanged(_ state: ConversationViewState) {
      guard state.historyReads != historyReads || !state.isLoadingHistory else { return }
      if state.historyReads != historyReads { olderRequested = false }
      historyReads = state.historyReads
    }

    /// Another session's rows are coming: it opens at its latest turn.
    func sessionOpened(_ id: String) {
      sessionID = id
      follow.reset()
      needsFraming = true
      pendingShow = nil
      olderRequested = false
      position.reset()
      cancelJump()
      disclosures.reset()
      scrollView.setAccessibilityIdentifier("transcript-\(id)")
    }

    /// Rows changed: a follower goes to the end, and another reader stays on their row.
    func keepReader(_ anchor: ReadingAnchor?, isNewOutput: Bool) {
      if isNewOutput ? follow.contentChanged() : follow.layoutGrew() {
        pinBottom()
      } else if activeJump == nil {
        // A jump under way goes on to its row, wherever the rows put it.
        restore(anchor)
      }
    }
  }
#endif
