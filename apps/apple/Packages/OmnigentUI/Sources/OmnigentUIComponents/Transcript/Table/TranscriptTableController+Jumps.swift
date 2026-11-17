#if os(macOS)
  import AppKit
  import QuartzCore
  import SwiftUI

  /// A jump the table transcript animates, as the stack's `withAnimation` jumps are: the
  /// viewport's origin eases out to a target read again each frame, as rows measured on the way
  /// move it.
  @MainActor
  struct TranscriptTableJump {
    /// How long a jump takes, as the stack's.
    static let duration: CFTimeInterval = 0.25
    /// How often a jump moves the viewport: twice a 60 Hz display's frame.
    static let step: TimeInterval = 1.0 / 120

    let start: CGFloat
    let startedAt: CFTimeInterval
    let target: @MainActor () -> CGFloat
    /// Runs once the jump arrives.
    let arrived: @MainActor () -> Void

    /// The origin at `now`, and whether the jump has arrived.
    func origin(at now: CFTimeInterval) -> (offset: CGFloat, isDone: Bool) {
      let progress = min(1, max(0, (now - startedAt) / Self.duration))
      let eased = 1 - pow(1 - progress, 3)
      return (start + (target() - start) * CGFloat(eased), progress >= 1)
    }
  }

  extension TranscriptTableController {
    // MARK: Animated jumps

    /// Moves to `target`, animated unless motion is off or reduced; `arrived` runs at the end.
    func jump(
      to target: @escaping @MainActor () -> CGFloat,
      arrived: @escaping @MainActor () -> Void = {}
    ) {
      cancelJump()
      probe("transcript jump", "\(target()), \(follow)")
      // AppKit declares `window` unowned(unsafe); it is only compared here, never retained.
      guard animatesJumps, unsafe clipView.window != nil else {
        move(to: target())
        arrived()
        return
      }
      activeJump = TranscriptTableJump(
        start: clipView.bounds.minY, startedAt: CACurrentMediaTime(), target: target,
        arrived: arrived)
      // Each step reads the time, so steps faster than the display only land on its frames.
      let timer = Timer(
        timeInterval: TranscriptTableJump.step, target: self,
        selector: #selector(jumpStep(_:)), userInfo: nil, repeats: true)
      RunLoop.main.add(timer, forMode: .common)
      jumpTimer = timer
    }

    @objc func jumpStep(_ timer: Timer) {
      guard let jump = activeJump else {
        cancelJump()
        return
      }
      let (offset, isDone) = jump.origin(at: CACurrentMediaTime())
      move(to: offset)
      guard isDone else { return }
      cancelJump()
      jump.arrived()
    }

    /// Stops a jump under way where it is: the reader scrolled, or another jump began.
    func cancelJump() {
      jumpTimer?.invalidate()
      jumpTimer = nil
      activeJump = nil
    }

    // MARK: Previous and next message

    /// Moves to the previous or next user message, from the rows on screen. With none above,
    /// older history loads; with none below, the newest row shows.
    func step(_ direction: TranscriptNavigation.Direction) {
      let users = Set(model.rows.filter(\.isUserMessage).map(\.id))
      let target = TranscriptNavigation.target(
        direction, order: model.ids, userMessages: users, visible: Set(visibleRowIDs))
      guard let target else {
        if direction == .previous { loadOlderPage() } else { jumpToLatest(animated: true) }
        return
      }
      show(target, at: .top, animated: true)
    }

    // MARK: Jump to top

    /// The first row of the history read so far, from the source: the list shows its rows a
    /// tick later.
    var sourceTopRowID: String? { sourceTopRow() }

    /// Jump to top pages in the rest of the history first, as the web does, and shows it once
    /// it is all read, not page by page above the reader.
    func jumpToTop() {
      follow.readEarlier()
      needsFraming = false
      pendingShow = nil
      if let state, state.hasMoreHistory, actions.loadOlder != nil {
        position.seeksTop = true
        holdRows()
        loadOlderPage()
      } else {
        jump(
          to: { [weak self] in self?.minimumOffset ?? 0 },
          arrived: { [weak self] in self?.moveToTop() })
      }
    }

    /// Asks for the page above the loaded rows, remembering where the history started.
    func loadOlderPage() {
      guard let state, state.hasMoreHistory, !state.isLoadingHistory,
        let loadOlder = actions.loadOlder
      else { return }
      position.awaitsPage = true
      position.topBeforePage = sourceTopRowID
      olderRequested = true
      loadOlder()
    }

    /// A read of older history ended. Jump to top keeps paging while pages add rows; a failed
    /// or empty page stops it where it is. The page's rows may reach the list before or after.
    func olderHistoryEnded() {
      guard let state else { return }
      let hasMore = state.hasMoreHistory && actions.loadOlder != nil
      switch position.pageEnded(sourceTop: sourceTopRowID, hasMore: hasMore) {
      case .settled: break
      case .readNext: loadOlderPage()
      case .arrive:
        releaseRows()
        arriveAtTop()
      }
    }

    /// The list's first row changed: Jump to top arrives once the rows read are shown.
    func firstRowChanged() {
      if position.seeksTop { arriveAtTop() }
    }

    /// Ends Jump to top at the first row, once the list shows the rows that were read.
    func arriveAtTop() {
      guard position.arrivesAtTop, state?.rows.first?.id == sourceTopRowID else { return }
      position.endSeekingTop()
      probe("transcript jump", "top from \(Int(clipView.bounds.minY))")
      moveToTop()
      reportVisibleRows()
    }
  }
#endif
