#if os(iOS)
  import Observation
  import SwiftUI
  import UIKit

  extension TranscriptCollectionController {
    // MARK: Text rows

    /// The message row `index` shows as text (``TranscriptCollectionTextView``), or `nil` when
    /// the row stays hosted in SwiftUI.
    func textMessage(at index: Int) -> TranscriptTableTextMessage? {
      guard model.rows.indices.contains(index) else { return nil }
      return textStyle.message(for: model.rows[index], version: model.version(at: index))
    }

    /// The kind of view row `index` shows in.
    func cellKind(at index: Int) -> TranscriptTableCellKind {
      let row = model.rows[index]
      return textMessage(at: index) != nil ? .text(row.kind) : .hosted(row.kind)
    }

    func makeTextView() -> TranscriptCollectionTextView {
      textViewsMade += 1
      let view = TranscriptCollectionTextView(style: textStyle)
      view.sizeChanged = { [weak self] in self?.scheduleRemeasure($0) }
      view.drawingLanded = { [weak self] in self?.drawingLanded($0) }
      view.cannotDraw = { [weak self] in self?.textCannotDraw(rowID: $0) }
      view.redrawPosition = { [weak self] in self?.redrawPosition(ofRow: $0) }
      return view
    }

    /// Where row `id`'s middle is in the content, for a drawing of its run at a new width,
    /// which the prewarm then leaves to that drawing.
    func redrawPosition(ofRow id: String) -> Double? {
      guard let index = model.index(of: id), index < offsets.count else { return nil }
      prewarmed[id] = model.version(at: index)
      return Double(frame(ofRow: index).midY)
    }

    /// Tells the drawing of runs at a new width where the reader is: the nearest go first.
    func focusRedraws() {
      guard textStyle.isEnabled else { return }
      let middle = collectionView.contentOffset.y + insets.top + visibleHeight / 2
      textStyle.redraws.focus(at: Double(middle))
    }

    /// Records row `index`'s height as a text row shows it, from its run's laid-out size, with
    /// no view; a row whose text can't be drawn is SwiftUI's from now on, and measured so.
    /// - Parameters:
    ///   - index: The row.
    ///   - message: The message it shows.
    ///   - draws: The row is about to show: a run not laid out yet is drawn now.
    /// - Returns: Whether the layout has another height for it.
    func measureText(_ index: Int, _ message: TranscriptTableTextMessage, draws: Bool) -> Bool {
      guard
        let height = textStyle.measuredHeight(of: message, width: model.width, draws: draws)
      else {
        textStyle.keepHosted(model.rows[index].id, version: model.version(at: index))
        return measureAway(index)
      }
      measurements += 1
      return model.record(height, at: index)
    }

    /// A text row found it can't draw row `rowID`'s text: the row's cell shows it hosted.
    func textCannotDraw(rowID: String) {
      guard !isConfiguring, let index = model.index(of: rowID) else { return }
      reconfigureRealized(index)
    }

    /// Gives the cell showing row `index`, if one does, the view for the row's kind now, and
    /// lays out its height.
    func reconfigureRealized(_ index: Int) {
      guard index < itemCount,
        let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
          as? TranscriptCollectionCell
      else { return }
      configure(cell, at: index)
      noteNextPass(index)
    }

    /// How often idle measuring looks again for a message the prewarm is building, and how
    /// long it waits for one before building it itself.
    static let prewarmWait: TimeInterval = 0.03
    static let prewarmPatience: CFTimeInterval = 0.5

    /// Whether idle measuring leaves row `index` to the prewarm for now: a message drawn as text
    /// that is not built yet, for a while. One citing workspace paths builds here.
    func awaitsPrewarm(_ index: Int) -> Bool {
      guard let message = textMessage(at: index), textStyle.hasPrewarms,
        message.split.cited.isEmpty, !textStyle.isBuilt(message)
      else { return false }
      let id = model.rows[index].id
      let now = CACurrentMediaTime()
      if let awaited = prewarmAwaited, awaited.id == id {
        return now - awaited.since < Self.prewarmPatience
      }
      prewarmAwaited = (id, now)
      let rect = frame(ofRow: index)
      prewarmTexts(from: rect.minY, to: rect.maxY)
      return true
    }

    // MARK: Text style

    /// Takes the transcript's environment for the text rows: a new style has every row pick its
    /// kind again, and the text rows on screen show again in it, once SwiftUI's update that
    /// handed the environment over is done.
    func syncTextStyle(_ values: EnvironmentValues) {
      let wasEnabled = textStyle.isEnabled
      guard textStyle.refresh(from: values) else { return }
      prewarmed = [:]
      textStyle.notePrewarms(width: model.width)
      if textStyle.isEnabled != wasEnabled { textKindsChanged = true }
      guard !awaitsTextStyle else { return }
      awaitsTextStyle = true
      MainRunLoop.perform { [weak self] in
        MainActor.assumeIsolated { self?.textStyleChanged() }
      }
    }

    func textStyleChanged() {
      awaitsTextStyle = false
      let kindsChanged = textKindsChanged
      textKindsChanged = false
      guard itemCount == model.rows.count, model.width > 0 else { return }
      // Rows that change kind may take another height; those on screen are measured now.
      if kindsChanged { model.invalidateHeights() }
      var noted = IndexSet()
      for case let cell as TranscriptCollectionCell in collectionView.visibleCells {
        guard let index = collectionView.indexPath(for: cell)?.item,
          model.rows.indices.contains(index)
        else { continue }
        if cell.host?.kind != cellKind(at: index) {
          configure(cell, at: index)
          noted.insert(index)
        } else if let host = cell.host as? TranscriptCollectionTextView, measure(index, with: host)
        {
          noted.insert(index)
        }
      }
      if kindsChanged {
        measureShownRows()
        rebuildOffsets()
        schedulePrefetch()
      }
      noteHeights(noted)
    }

    // MARK: Prewarm

    /// How many viewports past the measured lookahead a scroll builds and draws messages ahead.
    static let prewarmReach: CGFloat = 2

    /// Hands the settled messages from `minY` to `maxY` that text rows draw to the prewarms,
    /// each once per version, at its place, so they build and draw off the main thread before
    /// they scroll in, nearest the reader first.
    func prewarmTexts(from minY: CGFloat, to maxY: CGFloat, upward: Bool = false) {
      guard textStyle.isEnabled, offsets.count == model.rows.count, minY < maxY else { return }
      var indexes = Array(offsets.rows(from: minY, to: maxY))
      if upward { indexes.reverse() }
      var answers: (texts: [String], positions: [Double]) = ([], [])
      var prompts: (texts: [String], positions: [Double]) = ([], [])
      for index in indexes where model.rows.indices.contains(index) {
        let id = model.rows[index].id
        let version = model.version(at: index)
        guard prewarmed[id] != version, let message = textMessage(at: index) else { continue }
        prewarmed[id] = version
        let position = Double(frame(ofRow: index).midY)
        switch message.role {
        case .answer:
          answers.texts.append(message.markdown)
          answers.positions.append(position)
        case .user:
          prompts.texts.append(message.markdown)
          prompts.positions.append(position)
        }
      }
      MessageTextRunPrewarm.answers.prioritize(answers.texts, at: answers.positions)
      MessageTextRunPrewarm.prompts.prioritize(prompts.texts, at: prompts.positions)
    }

    /// The reader is still: the messages within ``keptReach`` viewports either way build and
    /// draw first, nearest the viewport first.
    func prewarmAroundViewport() {
      guard textStyle.isEnabled else { return }
      let shown = collectionView.bounds
      let kept = shown.insetBy(dx: 0, dy: -shown.height * Self.keptReach)
      focusPrewarms(at: shown.midY, direction: 0)
      prewarmTexts(from: kept.minY, to: kept.maxY)
    }

    /// Tells the prewarms where the reader is and which way they scroll.
    func focusPrewarms(at position: CGFloat, direction: Int) {
      guard textStyle.isEnabled else { return }
      for prewarm in [MessageTextRunPrewarm.answers, .prompts] {
        prewarm.focus(at: Double(position), direction: direction)
      }
    }

    /// Asks for the messages a scroll reaches next: past the viewport's edge it moves toward,
    /// through the lookahead and ``prewarmReach`` viewports more.
    func prewarmAhead(top: CGFloat, height: CGFloat, upward: Bool) {
      guard textStyle.isEnabled else { return }
      let reach = height * (Self.lookahead + Self.prewarmReach)
      focusPrewarms(at: upward ? top : top + height, direction: upward ? -1 : 1)
      if upward {
        prewarmTexts(from: top - reach, to: top, upward: true)
      } else {
        prewarmTexts(from: top + height, to: top + height + reach)
      }
    }

    // MARK: Flash

    /// Follows the window's linked-message flash: the text row showing the flashed row tints,
    /// as a SwiftUI row reading the focus does.
    func watchFlash() {
      guard !awaitsFlash, let focus = environment.values?.transcriptFocus else { return }
      awaitsFlash = true
      let flashed = withObservationTracking {
        focus.flashedRowID
      } onChange: { [weak self] in
        MainRunLoop.perform {
          MainActor.assumeIsolated {
            self?.awaitsFlash = false
            self?.watchFlash()
          }
        }
      }
      for case let cell as TranscriptCollectionCell in collectionView.visibleCells {
        (cell.host as? TranscriptCollectionTextView)?.showFlash(flashed)
      }
    }
  }
#endif
