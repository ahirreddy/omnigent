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
    private var styleSerial = -1
    private(set) var message: TranscriptTableTextMessage?
    /// One view per run of text blocks, top to bottom.
    private(set) var runs: [TranscriptTableTextRun] = []
    /// The runs shown as live text views.
    var texts: [MessageTextContentView] {
      runs.compactMap {
        if case .live(let view) = $0 { return view }
        return nil
      }
    }
    private let bubbleView = TranscriptTableBubbleView()
    private var workedLabel: NSTextField?
    var actionsView: TranscriptMessageActionsView?
    /// Where the actions' row starts (under the text, or on the "Worked for" line) and ends.
    private(set) var actionsTop: CGFloat = 0
    private(set) var actionsLineHeight: CGFloat = 0
    private(set) var actionsTrailing: CGFloat = 0
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

    init(style: TranscriptTableTextStyle) {
      self.style = style
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
      guard let message = TranscriptTableTextMessage.make(row, ramp: style.ramp),
        let textStyle = style.style
      else {
        releaseContent()
        return
      }
      shown = next
      shownRow = row
      kind = .text(row.kind)
      styleSerial = style.serial
      self.message = message
      var documents: [Int: MessageTextDocument] = [:]
      var untypeset: [String] = []
      for run in message.runs {
        let math = Self.typesetMath(run.inlineMath, ramp: textStyle.ramp)
        untypeset += run.inlineMath.filter { math[$0] == nil }
        documents[run.id] = MessageTextBlocksView.document(
          source: MessageTextSource(text: message.markdown, piece: run.id), blocks: run.blocks,
          linked: [], math: math, style: textStyle, links: nil)
      }
      typeset(untypeset, ramp: textStyle.ramp, for: next)
      let metrics = style.metrics(width: width)
      let textWidth =
        message.role == .answer ? metrics.columnWidth : metrics.promptWidth(style.layoutWidth)
      laidOut = (metrics, textWidth)
      adopt(message.split.pieces, documents: documents, width: textWidth)
      let openURL = (style.environment.values?.openURL).map { open in
        { @MainActor (url: URL) in open(url) }
      }
      for run in runs { run.setOpenURL(openURL) }
      setAccessibilityIdentifier("message-\(message.row.id)")
      setAccessibilityLabel(message.role == .user ? "You said" : nil)
      if message.role == .answer {
        runs.first?.view.setAccessibilityIdentifier("message-text-\(message.row.id)")
      }
      let previous = height
      height = layOutContent(metrics: metrics, textWidth: textWidth, message: message)
      refreshActions()
      if isRestyle, abs(previous - height) >= 0.5 { idealSizeChanged?(self) }
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

    /// A live text view's height changed by itself (a code block's Wrap turned): the cell lays
    /// out again on the next pass and tells the table. AppKit's own calls while the cell shows
    /// or lays out change nothing it isn't laying out already.
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

    /// Hands the text views back for the next cell that shows their documents.
    func releaseContent() {
      typesetting?.cancel()
      typesetting = nil
      shownRow = nil
      for run in runs { run.release() }
      runs = []
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

    // MARK: Layout

    /// Places the text, the bubble and the footer; returns the row's height.
    private func layOutContent(
      metrics: TranscriptTableTextMetrics, textWidth: CGFloat, message: TranscriptTableTextMessage
    ) -> CGFloat {
      switch message.role {
      case .answer: layOutAnswer(metrics: metrics, textWidth: textWidth, message: message)
      case .user: layOutPrompt(metrics: metrics, textWidth: textWidth, message: message)
      }
    }

    /// An answer: its runs down the column, then its footer.
    private func layOutAnswer(
      metrics: TranscriptTableTextMetrics, textWidth: CGFloat, message: TranscriptTableTextMessage
    ) -> CGFloat {
      bubbleView.isHidden = true
      if let palette = style.palette, textWidth >= MessageTextContentView.minimumWidth {
        // The answers after this one lay out (and draw) ahead at this width.
        MessageTextPrewarm.shared.note(
          palette: palette, width: textWidth, scale: style.drawsAhead ? style.scale : 0,
          raster: style.drawsAhead ? style.rasterStyle : nil)
      }
      let frames = TranscriptTableTextFrames(
        role: .answer, gaps: message.split.pieces.map(\.gapAbove),
        sizes: runs.map { $0.size(for: textWidth, fillsWidth: true) }, metrics: metrics,
        workedHeight: message.decoration.workedFor.map { _ in Self.workedLabelHeight })
      place(frames)
      if let workedFor = message.decoration.workedFor, let frame = frames.worked {
        let label = workedLabel ?? makeWorkedLabel()
        label.stringValue = TurnElapsed.worked(workedFor)
        label.toolTip = message.decoration.timestamp.map {
          "Finished \(MessageTimestamp.format($0, now: Date()))"
        }
        label.frame = frame
        label.isHidden = false
      } else {
        workedLabel?.isHidden = true
      }
      return frames.height
    }

    /// A user's prompt: its runs in a bubble that hugs them, at the column's trailing edge.
    private func layOutPrompt(
      metrics: TranscriptTableTextMetrics, textWidth: CGFloat, message: TranscriptTableTextMessage
    ) -> CGFloat {
      workedLabel?.isHidden = true
      if let palette = style.palette, textWidth >= MessageTextContentView.minimumWidth {
        // The prompts after this one draw ahead at this width.
        MessageTextPrewarm.prompts.note(
          palette: palette, width: textWidth, scale: style.drawsAhead ? style.scale : 0,
          raster: style.drawsAhead ? style.rasterStyle : nil)
      }
      let frames = TranscriptTableTextFrames(
        role: .user, gaps: message.split.pieces.map(\.gapAbove),
        sizes: runs.map { $0.size(for: textWidth, fillsWidth: false) }, metrics: metrics,
        workedHeight: nil)
      place(frames)
      if let bubble = frames.bubble {
        bubbleView.frame = bubble
        bubbleView.color = style.bubble
        bubbleView.isHidden = false
      }
      return frames.height
    }

    /// Puts the runs where `frames` says, and the actions' row.
    private func place(_ frames: TranscriptTableTextFrames) {
      for (run, frame) in zip(runs, frames.pieces) { run.view.frame = frame }
      actionsTop = frames.actionsTop
      actionsLineHeight = frames.actionsLineHeight
      actionsTrailing = frames.actionsTrailing
    }

    /// The "Worked for" line's height: its caption's.
    static let workedLabelHeight: CGFloat = {
      let label = NSTextField(labelWithString: "Worked for 1s")
      label.font = .preferredFont(forTextStyle: .caption1)
      return label.intrinsicContentSize.height.rounded(.up)
    }()

    private func makeWorkedLabel() -> NSTextField {
      let label = NSTextField(labelWithString: "")
      label.font = .preferredFont(forTextStyle: .caption1)
      label.textColor = .secondaryLabelColor
      label.setAccessibilityIdentifier("worked-for")
      addSubview(label)
      workedLabel = label
      return label
    }
  }

  extension TranscriptTableTextCell {
    /// Lets the drawn runs' bitmaps go once the cell leaves the table: the rasters' cache keeps
    /// them under its memory budget, and showing the cell again takes them back from it.
    func releaseBitmaps() {
      for case .raster(let view) in runs { view.releaseBitmap() }
    }

    /// Takes the drawn runs' bitmaps back from the rasters' cache.
    /// - Returns: Whether every run shows its drawing again, with none left live.
    /// Whether a run shown live has its drawing kept now, which showing the cell again would
    /// take: not one the reader is selecting in.
    var hasArrivedDrawing: Bool {
      guard style.drawsAhead, let laidOut else { return false }
      return runs.contains { run in
        guard case .live(let view) = run, unsafe view.window?.firstResponder !== view.textView
        else { return false }
        return MessageTextRasters.shared.contains(
          MessageTextRasterKey(
            document: view.document.serial, width: laidOut.textWidth, scale: style.scale))
      }
    }

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
        guard typeset, !Task.isCancelled, let self, self.shown == shown,
          let row = self.shownRow
        else { return }
        let previous = self.height
        self.shown = nil
        self.show(row, version: shown.version, width: shown.width)
        if abs(previous - self.height) >= 0.5 { self.idealSizeChanged?(self) }
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
