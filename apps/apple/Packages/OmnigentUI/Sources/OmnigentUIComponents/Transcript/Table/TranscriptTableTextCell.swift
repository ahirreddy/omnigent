#if os(macOS)
  import AppKit
  import OmnigentPlatform
  import SwiftUI

  /// A cell that draws a settled message in AppKit: its markdown as TextKit text
  /// (``MessageTextContentView``, laid out once per width and kept), a user's bubble, and the
  /// actions that hover reveals. Its height comes from the text's measurement, with no SwiftUI
  /// pass.
  final class TranscriptTableTextCell: NSView, TranscriptTableCell {
    private(set) var shown: TranscriptTableShown?
    private(set) var kind: TranscriptTableCellKind?
    var idealSizeChanged: ((any TranscriptTableCell) -> Void)?

    let style: TranscriptTableTextStyle
    /// Which long prompts the reader showed whole.
    let folds: TranscriptTableFolds
    private var styleSerial = -1
    private(set) var message: TranscriptTableTextMessage?
    /// One view per run of text blocks, top to bottom.
    private(set) var runs: [TranscriptTableTextRun] = []
    /// One hosting view per part beside the text, top to bottom.
    private(set) var accessoryViews: [TranscriptTableAccessoryView] = []
    /// The runs shown as live text views.
    var texts: [MessageTextContentView] {
      runs.compactMap {
        if case .live(let view) = $0 { return view }
        return nil
      }
    }
    let bubbleView = TranscriptTableBubbleView()
    var workedLabel: NSTextField?
    var actionsView: TranscriptMessageActionsView?
    /// Where the actions' row starts (under the text, or on the "Worked for" line) and ends.
    var actionsTop: CGFloat = 0
    var actionsLineHeight: CGFloat = 0
    var actionsTrailing: CGFloat = 0
    /// The message's own frame, as its SwiftUI row lays it out.
    var contentFrame: CGRect = .zero
    /// A linked message's tint, the row it tints for, and the wait before it fades.
    var flashView: NSView?
    var flashingRowID: String?
    var flashFading: Task<Void, Never>?
    private var height: CGFloat = 0
    /// The column and text width the cell last laid out at.
    private var laidOut: (metrics: TranscriptTableTextMetrics, textWidth: CGFloat)?
    var isHovered = false
    var hoverArea: NSTrackingArea?
    /// The row shown, to show again once its inline math is typeset.
    private var shownRow: TranscriptTableRow?
    /// Showing or laying out now, or waiting to lay out again on the next pass.
    private var isLayingOut = false
    private var awaitsLayout = false
    /// Typesets the inline math the shown message doesn't have yet.
    private var typesetting: Task<Void, Never>?
    /// Lists the folders of the workspace paths the shown message cites, while in a window.
    var linkCheck: Task<Void, Never>?
    /// Counts reads of the links' state; only the latest read's change shows the row again.
    var linkWatch = 0

    init(style: TranscriptTableTextStyle, folds: TranscriptTableFolds = TranscriptTableFolds()) {
      self.style = style
      self.folds = folds
      super.init(frame: .zero)
      bubbleView.isHidden = true
      addSubview(bubbleView)
      setAccessibilityElement(true)
      setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    // MARK: Showing

    func show(_ row: TranscriptTableRow, version: Int, width: CGFloat) {
      isLayingOut = true
      defer { isLayingOut = false }
      let next = TranscriptTableShown(id: row.id, version: version, width: width)
      guard next != shown || styleSerial != style.serial || awaitsRasters else { return }
      // Shown again as it was: its drawings come back from the cache, if all are there.
      if next == shown, styleSerial == style.serial, takeBitmapsBack() { return }
      // The same content in a new style may take another height, which the table then asks.
      let isRestyle = next == shown
      guard
        let message = TranscriptTableTextMessage.make(
          row, ramp: style.ramp, expandsPrompt: folds.isExpanded(row.id, isLive: false)),
        let textStyle = style.style
      else {
        releaseContent()
        return
      }
      let isNewRow = next.id != shown?.id || next.version != shown?.version
      shown = next
      shownRow = row
      kind = .text(row.kind)
      styleSerial = style.serial
      self.message = message
      if isNewRow { restartLinkCheck() }
      let documents = documents(for: message, in: textStyle, shown: next)
      let metrics = style.metrics(width: width)
      let textWidth =
        message.role == .answer ? metrics.columnWidth : metrics.promptWidth(style.layoutWidth)
      laidOut = (metrics, textWidth)
      adopt(message.split.pieces, documents: documents, width: textWidth)
      adoptAccessories(message.accessories, rowID: message.row.id, width: textWidth)
      let openURL = style.environment.values.map(Self.openURL(in:))
      for run in runs { run.setOpenURL(openURL) }
      setAccessibilityIdentifier("message-\(message.row.id)")
      setAccessibilityLabel(message.role == .user ? "You said" : nil)
      if message.role == .answer {
        runs.first?.view.setAccessibilityIdentifier("message-text-\(message.row.id)")
      }
      let previous = height
      height = layOutContent(metrics: metrics, textWidth: textWidth, message: message)
      refreshActions()
      showFlash(style.environment.values?.transcriptFocus?.flashedRowID)
      if isRestyle, abs(previous - height) >= 0.5 { idealSizeChanged?(self) }
    }

    /// Each text run's document, with its cited paths linked as far as they are known and the
    /// inline math typeset so far; the rest of the math typesets for `shown` now.
    private func documents(
      for message: TranscriptTableTextMessage, in textStyle: MessageTextStyle,
      shown: TranscriptTableShown
    ) -> [Int: MessageTextDocument] {
      let links = style.environment.values?.workspaceFileLinks
      let linked = linkedPaths(of: message, links: links)
      var documents: [Int: MessageTextDocument] = [:]
      var untypeset: [String] = []
      for run in message.runs {
        let math = Self.typesetMath(run.inlineMath, ramp: textStyle.ramp)
        untypeset += run.inlineMath.filter { math[$0] == nil }
        documents[run.id] = MessageTextBlocksView.document(
          source: MessageTextSource(text: message.markdown, piece: run.id), blocks: run.blocks,
          linked: linked, math: math, style: textStyle, links: links)
      }
      typeset(untypeset, ramp: textStyle.ramp, for: shown)
      return documents
    }

    /// Shows `pieces` laid out `width` wide. A text run shows as a raster drawn ahead when the
    /// surface draws runs ahead and one is kept, else as a live view borrowed from
    /// ``MessageTextViews`` (and drawn ahead for next time); a block is hosted. Views that
    /// already show a piece stay.
    private func adopt(
      _ pieces: [MessageTextPiece], documents: [Int: MessageTextDocument], width: CGFloat
    ) {
      var kept: [UInt64: TranscriptTableTextRun] = [:]
      var keptBlocks: [Int: TranscriptTableBlockView] = [:]
      for run in runs {
        if let document = run.document { kept[document.serial] = run }
        if case .block(let view) = run { keptBlocks[view.piece] = view }
      }
      var adopted: [TranscriptTableTextRun] = []
      for piece in pieces {
        guard let document = documents[piece.id] else {
          guard case .block(let block) = piece.content else { continue }
          let view = keptBlocks.removeValue(forKey: piece.id) ?? makeBlockView()
          view.show(block, piece: piece.id, width: width)
          adopted.append(.block(view))
          continue
        }
        // A run whose long lines the reader set scrolling sideways shows live.
        let raster =
          style.liveDocuments.contains(document.serial)
          ? nil : style.raster(for: document, width: width)
        if let run = kept.removeValue(forKey: document.serial) {
          if run.keeps(raster, width: width, style: style) {
            adopted.append(run)
            continue
          }
          run.release()
        }
        adopted.append(makeRun(document, raster: raster, width: width))
      }
      for run in kept.values { run.release() }
      for view in keptBlocks.values { TranscriptTableTextRun.block(view).release() }
      runs = adopted
    }

    /// Shows message `rowID`'s parts beside its text, each offered `width`, in the views that
    /// show parts already, in order; views left over go.
    private func adoptAccessories(
      _ accessories: [TranscriptTableAccessory], rowID: String, width: CGFloat
    ) {
      var adopted: [TranscriptTableAccessoryView] = []
      for (index, accessory) in accessories.enumerated() {
        let view =
          accessoryViews.indices.contains(index) ? accessoryViews[index] : makeAccessoryView()
        view.show(accessory, rowID: rowID, width: width)
        adopted.append(view)
      }
      for view in accessoryViews.dropFirst(accessories.count) { release(view) }
      accessoryViews = adopted
    }

    private func release(_ view: TranscriptTableAccessoryView) {
      view.sizeChanged = nil
      view.removeFromSuperview()
    }

    /// A hosted block took another height: the cell lays out again and tells the table.
    func blockSizeChanged() {
      guard let message, let laidOut, !isLayingOut else { return }
      isLayingOut = true
      defer { isLayingOut = false }
      let previous = height
      height = layOutContent(
        metrics: laidOut.metrics, textWidth: laidOut.textWidth, message: message)
      refreshActions()
      if abs(previous - height) >= 0.5 { idealSizeChanged?(self) }
    }

    /// A live text view's or a hosted piece's height changed by itself (a code block's Wrap
    /// turned, a part opened): the cell lays out again on the next pass and tells the table.
    /// AppKit's own calls while the cell shows or lays out change nothing it isn't laying out
    /// already.
    override func invalidateIntrinsicContentSize() {
      guard !isLayingOut, !awaitsLayout, message != nil else { return }
      awaitsLayout = true
      MainRunLoop.perform { [weak self] in
        MainActor.assumeIsolated {
          self?.awaitsLayout = false
          self?.blockSizeChanged()
        }
      }
    }

    /// The reader showed a long prompt whole, or collapsed it again: the choice outlasts the
    /// cell, and the prompt shows again once the button's press is over.
    func togglePrompt() {
      guard let message, let fold = message.promptFold else { return }
      folds.setExpanded(fold == .collapsed, for: message.row.id)
      MainRunLoop.perform { [weak self] in
        MainActor.assumeIsolated { self?.showAgain() }
      }
    }

    /// Shows the row again as if it were new: its math typeset or its links found since.
    func showAgain() {
      guard let shown, let row = shownRow else { return }
      let previous = height
      self.shown = nil
      show(row, version: shown.version, width: shown.width)
      if abs(previous - height) >= 0.5 { idealSizeChanged?(self) }
    }

    /// Hands the text views back for the next cell that shows their documents.
    func releaseContent() {
      typesetting?.cancel()
      typesetting = nil
      stopLinkCheck()
      endFlash()
      shownRow = nil
      for run in runs { run.release() }
      runs = []
      for view in accessoryViews { release(view) }
      accessoryViews = []
      shown = nil
      message = nil
    }

    var idealHeight: CGFloat { height }

    /// Whether a run shows live while runs draw ahead: its drawing may have arrived since.
    /// A drawn run that let its bitmap go off screen takes it back too.
    private var awaitsRasters: Bool {
      style.drawsAhead
        && runs.contains {
          switch $0 {
          case .live: true
          case .raster(let view): view.isReleased
          case .block: false
          }
        }
    }

    /// Its height is the text's, known at show: nothing reports later.
    func settle() {}
  }

  extension TranscriptTableTextCell {
    /// Lets the drawn runs' bitmaps go once the cell leaves the table: the rasters' cache keeps
    /// them under its memory budget, and showing the cell again takes them back from it.
    func releaseBitmaps() {
      for case .raster(let view) in runs { view.releaseBitmap() }
    }

    /// Takes the drawn runs' bitmaps back from the rasters' cache.
    /// - Returns: Whether every run shows its drawing again, with none left live.
    fileprivate func takeBitmapsBack() -> Bool {
      var shown = true
      for run in runs {
        switch run {
        case .raster(let view) where view.isReleased:
          if let raster = MessageTextRasters.shared.raster(for: view.key) {
            view.show(raster)
          } else {
            shown = false
          }
        case .live:
          shown = false
        case .raster, .block:
          break
        }
      }
      return shown
    }

    /// Typesets `math` the shown message doesn't have yet, then shows it again with it; math
    /// KaTeX rejects keeps its Unicode form, as in ``MarkdownParagraphText``.
    fileprivate func typeset(_ math: [String], ramp: TypeRamp, for shown: TranscriptTableShown) {
      typesetting?.cancel()
      typesetting = nil
      guard !math.isEmpty else { return }
      typesetting = Task { [weak self] in
        var typeset = false
        for tex in math {
          let request = Self.mathRequest(tex, ramp: ramp)
          do {
            let image = try await RichBlockRenderer.shared.render(request)
            MessageTextTypesetMath.shared.store(image, for: request)
            typeset = true
          } catch is CancellationError {
            return
          } catch {
            continue
          }
        }
        guard typeset, !Task.isCancelled, let self, self.shown == shown else { return }
        self.showAgain()
      }
    }

    /// The reader turned a drawn run's code block Wrap: long lines that scroll sideways need
    /// the live text, which shows instead of the drawing from now on.
    func showLive(_ document: MessageTextDocument, block: Int, wraps: Bool) {
      style.liveDocuments.insert(document.serial)
      guard let index = runs.firstIndex(where: { $0.document === document }),
        case .raster(let drawn) = runs[index], let laidOut
      else { return }
      let openURL = drawn.openURL
      runs[index].release()
      let view = MessageTextViews.shared.checkOut(document)
      view.openURL = openURL
      addSubview(view)
      runs[index] = .live(view)
      if index == 0, message?.role == .answer, let id = message?.row.id {
        view.setAccessibilityIdentifier("message-text-\(id)")
      }
      view.setWraps(wraps, block: block)
      // The header pressed was the drawing's; the live text's own shows the same state.
      _ = view.measurement(for: laidOut.textWidth)
      (view.chromeViews[block] as? MessageCodeHeaderView)?.wrapsLines = wraps
      blockSizeChanged()
    }
  }
#endif
