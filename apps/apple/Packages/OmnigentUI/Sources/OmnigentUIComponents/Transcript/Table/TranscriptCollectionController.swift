#if os(iOS)
  import SwiftUI
  import UIKit

  /// The transcript list's UIKit side on iPhone and iPad: a collection view with one item per
  /// transcript row, laid out in one column at the heights of ``TranscriptTableModel``. Cells hold
  /// row views kept by row id: SwiftUI row hosts (``TranscriptCollectionRowHost``), and with the
  /// TextKit renderer, settled messages drawn as text (``TranscriptCollectionTextView``), built
  /// and drawn ahead off the main thread. Heights are measured once per row, content version and
  /// width, ahead of the scroll and while the reader is still, and estimated until then. It
  /// keeps the Mac table's follow rules and paging, and the touch transcript's keyboard and
  /// width changes.
  @MainActor
  final class TranscriptCollectionController: NSObject, UICollectionViewDataSource,
    UICollectionViewDelegate
  {
    /// Where a shown row lands.
    enum Placement {
      case top
      case center
    }

    /// The row under the viewport's top and how far into it the top is.
    struct ReadingAnchor: Equatable {
      var id: String
      var offset: CGFloat
      /// The same as a share of the row's height, for a row a new width made taller or shorter.
      var fraction: CGFloat
    }

    /// How close to the top, in points, reading starts loading older history.
    static let olderHistoryReach: CGFloat = 400
    /// How close to the end counts as at the bottom.
    static let bottomReach: CGFloat = Theme.Spacing.extraLarge + 16
    /// Of a viewport, how far ahead of a scroll rows are measured before they show.
    static let lookahead: CGFloat = 0.75
    /// The main thread time one layout pass may spend measuring rows not yet in view.
    static let lookaheadBudget: CFTimeInterval = 0.003
    /// The main thread time one idle pass may spend measuring rows away from the viewport.
    static let prefetchBudget: CFTimeInterval = 0.004
    /// How many viewports above and below idle measuring reaches.
    static let prefetchReach: CGFloat = 5
    /// How many viewports away idle measuring keeps the hosts it measured in.
    static let keptReach: CGFloat = 1.5
    /// How long after the last move idle measuring starts.
    static let prefetchDelay: TimeInterval = 0.3
    /// Of a viewport, how far Jump to latest scrolls with animation; farther, it jumps.
    static let animatedJumpReach: CGFloat = 1.5

    /// The views, made when the list first shows: SwiftUI makes a controller with each update of
    /// the view that holds it, and keeps only the first.
    private(set) lazy var collectionView: UICollectionView = makeCollectionView()
    let environment = TranscriptTableEnvironment()
    lazy var layout = TranscriptCollectionLayout()
    lazy var cellRegistration = UICollectionView.CellRegistration<TranscriptCollectionCell, Int>(
      handler: { [weak self] cell, _, index in self?.configure(cell, at: index) })
    var model = TranscriptTableModel()
    /// The rows' tops, for the rows the collection view has been told about.
    var offsets = TranscriptRowOffsets()
    /// How many items the collection view has been told about.
    var itemCount = 0
    /// Whether the collection view has asked for its items since it was last reloaded.
    var hasLoadedItems = false
    var pool = TranscriptTableCellPool<any TranscriptCollectionRowView>(
      shownID: { $0.shownID }, kind: { $0.kind })
    /// One host per kind measures rows away from the viewport, whose hosts are not kept.
    var measuringHosts: [TranscriptTableRowKind: TranscriptCollectionRowHost] = [:]
    /// The style the text rows draw in.
    lazy var textStyle = TranscriptCollectionTextStyle(environment: environment)
    /// The content version of each row handed to the prewarms.
    var prewarmed: [String: Int] = [:]
    /// A cell is being given its row's view.
    var isConfiguring = false
    /// The rows idle measuring passed for the prewarm to build or draw, by id, and since when.
    var prewarmDeferred: [String: CFTimeInterval] = [:]
    /// The text style changed and the rows on screen show again in it next pass, picking their
    /// kinds again first when text rows turned on or off.
    var awaitsTextStyle = false
    var textKindsChanged = false
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
    /// The bars and the keyboard over the rows, and the screen's edges beside them.
    var insets = UIEdgeInsets.zero
    /// What the rows' heights were measured for besides their width.
    var metrics: TranscriptTableMetrics?
    var sessionID: String?
    var needsFraming = false
    var pendingShow: (id: String, placement: Placement)?
    var olderRequested = false
    var historyReads = 0
    var isShown = true

    var isAdjusting = false
    var isUserScrolling = false
    /// Jump to latest is scrolling to the end with an animation.
    var isJumpingToEnd = false
    /// The viewport's size at the last layout pass.
    var laidOutSize = CGSize.zero
    /// The content offset at the last layout pass, for the direction of the scroll.
    var laidOutOffset: CGFloat = 0
    var visibleRange = 0..<0
    var pendingHosts: [ObjectIdentifier: any TranscriptCollectionRowView] = [:]
    var awaitsRemeasure = false
    /// Rows measured while a cell was being made, whose heights the layout takes next pass.
    var pendingNotes = IndexSet()
    var awaitsNotes = false
    var awaitsMetrics = false
    var prefetchGeneration = 0
    var prefetchCursor: (above: Int, below: Int)?
    /// The keyboard's animation under way, so the insets it changes move with it.
    var keyboardAnimation: (curve: UInt, ends: CFTimeInterval)?

    /// Counts for tests and the performance log.
    var measurements = 0
    var hostsMade = 0
    var textViewsMade = 0
    /// Rows measured again because SwiftUI laid them out at another height once they showed,
    /// with both heights; the latest few.
    var remeasured: [String] = []

    func makeCollectionView() -> UICollectionView {
      layout.owner = self
      let view = TranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
      view.owner = self
      view.backgroundColor = .clear
      view.contentInsetAdjustmentBehavior = .never
      view.automaticallyAdjustsScrollIndicatorInsets = false
      view.alwaysBounceVertical = true
      view.showsHorizontalScrollIndicator = false
      view.keyboardDismissMode = .interactive
      // Rows are rendered ahead in kept hosts; a cell made early has nothing to add.
      view.isPrefetchingEnabled = false
      view.allowsSelection = false
      view.selfSizingInvalidation = .disabled
      view.dataSource = self
      view.delegate = self
      _ = cellRegistration
      NotificationCenter.default.addObserver(
        self, selector: #selector(keyboardWillChangeFrame),
        name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
      return view
    }

    // MARK: Updates

    /// Takes a SwiftUI update: the rows and the conversation, and the environment the cells
    /// render in until the environment's own feed hands it over.
    func update(
      rows: [TranscriptTableRow], state: ConversationViewState, actions: ConversationActions,
      isCLI: Bool, environment values: EnvironmentValues
    ) {
      _ = collectionView
      if environment.values == nil {
        environment.values = values
        metrics = TranscriptTableMetrics(values)
        syncTextStyle(values)
      }
      self.actions = actions
      self.isCLI = isCLI
      let previous = self.state
      take(state)
      watchFlash()
      // A width that came with this update, before a layout pass took it.
      let widthAnchor = readingAnchor(atOffset: laidOutOffset)
      if syncWidth() { widthChanged(keeping: widthAnchor) }
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

    /// Takes the conversation: another session starts over, and a page of history that ended
    /// lets the next one be asked for.
    func take(_ state: ConversationViewState) {
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
    }

    /// The transcript's environment changed: the cells take it, and a new text size measures
    /// every row again, keeping the reader on the row they read.
    func environmentChanged(_ values: EnvironmentValues) {
      environment.values = values
      syncTextStyle(values)
      let next = TranscriptTableMetrics(values)
      guard next != metrics else { return }
      metrics = next
      // Measured once the cells have rendered in the new environment.
      guard !awaitsMetrics else { return }
      awaitsMetrics = true
      MainRunLoop.perform { [weak self] in
        MainActor.assumeIsolated { self?.remeasureForMetrics() }
      }
    }

    func remeasureForMetrics() {
      awaitsMetrics = false
      guard hasRows, offsets.count == model.rows.count else { return }
      let anchor = readingAnchor()
      model.invalidateHeights()
      measureShownRows()
      rebuildOffsets()
      schedulePrefetch()
      if follow.layoutGrew() { pinBottom() } else { restore(anchor, proportionally: true) }
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
        collectionView.bounds.height > 0, offsets.count == model.rows.count
      else { return false }
      needsFraming = false
      frameLatestTurn()
      return true
    }

    /// Puts a change into the collection view without animation; kept rows on screen show their
    /// new content and are measured now, in this pass.
    func apply(_ change: TranscriptTableChange) {
      let isStructural = !change.removed.isEmpty || !change.inserted.isEmpty
      if isStructural {
        // A session's whole history replaced, or a list not loaded yet, reloads.
        if !hasLoadedItems || change.removed.count + change.inserted.count > 200 {
          for case let cell as TranscriptCollectionCell in collectionView.visibleCells {
            if let host = cell.detach() { pool.park(host) }
          }
          itemCount = model.rows.count
          rebuildOffsets(keepingGiven: true)
          hasLoadedItems = false
          collectionView.reloadData()
        } else {
          let removed = change.removed.map { IndexPath(item: $0, section: 0) }
          let inserted = change.inserted.map { IndexPath(item: $0, section: 0) }
          UIView.performWithoutAnimation {
            collectionView.performBatchUpdates(
              { [self] in
                // The layout answers for the old rows until the collection view takes the new.
                itemCount = model.rows.count
                rebuildOffsets(keepingGiven: true)
                collectionView.deleteItems(at: removed)
                collectionView.insertItems(at: inserted)
              }, completion: nil)
          }
        }
        if !change.removed.isEmpty { pool.keep(only: Set(model.ids)) }
        // Rows above moved the indices the idle measuring had reached.
        prefetchCursor = nil
      }
      var noted = IndexSet()
      for index in change.changed {
        guard let host = realizedHost(at: index) else { continue }
        // A row that settled, or stopped being the latest answer, may change kind.
        if host.kind != cellKind(at: index) {
          reconfigureRealized(index)
        } else if measure(index, with: host) {
          noted.insert(index)
        }
      }
      noteHeights(noted)
    }

    /// Lays every row out again at the heights the model has for them.
    /// - Parameter keepingGiven: Rows keep the heights the layout had for them; the others get
    ///   theirs. Rows arriving don't move the rows already there, whose estimates shift as rows
    ///   of their kind are measured.
    func rebuildOffsets(keepingGiven: Bool = false) {
      offsets.rebuild(count: itemCount) {
        keepingGiven ? model.givenHeight(at: $0) : model.provideHeight(at: $0)
      }
      layout.invalidateLayout()
    }

    /// Row `index`'s frame in the content.
    func frame(ofRow index: Int) -> CGRect {
      CGRect(
        x: insets.left, y: offsets.top(of: index), width: model.width,
        height: max(1, offsets.height(of: index)))
    }
  }

  extension TranscriptCollectionController {
    // MARK: Data source and delegate

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
      -> Int
    {
      hasLoadedItems = true
      return itemCount
    }

    func collectionView(
      _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
      collectionView.dequeueConfiguredReusableCell(
        using: cellRegistration, for: indexPath, item: indexPath.item)
    }

    /// Gives `cell` row `index`'s view: the one it already holds, one kept for the row, a
    /// spare; a text row that can't draw the row gives way to a SwiftUI host.
    func configure(_ cell: TranscriptCollectionCell, at index: Int) {
      guard model.rows.indices.contains(index) else { return }
      isConfiguring = true
      defer { isConfiguring = false }
      let row = model.rows[index]
      if let held = cell.host, held.shownID != row.id || held.kind != cellKind(at: index),
        let host = cell.detach()
      {
        pool.park(host)
      }
      var host = cell.host ?? keptView(at: index)
      present(index, in: host)
      if host.shownID != row.id {
        pool.park(host)
        host = keptView(at: index)
        present(index, in: host)
      }
      cell.attach(host)
    }

    /// Shows row `index` in `host`, measured now if it has to be, its height laid out next pass.
    private func present(_ index: Int, in host: any TranscriptCollectionRowView) {
      if model.needsMeasure(at: index) {
        if measure(index, with: host) { noteNextPass(index) }
      } else {
        host.show(model.rows[index], version: model.version(at: index), width: model.width)
      }
    }

    func collectionView(
      _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
      forItemAt indexPath: IndexPath
    ) {
      guard let cell = cell as? TranscriptCollectionCell, let host = cell.detach() else { return }
      host.didLeaveScreen()
      pool.park(host)
    }

    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath)
      -> Bool
    {
      false
    }
  }
#endif
