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
    var isHovered = false
    var hoverArea: NSTrackingArea?

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
      let next = TranscriptTableShown(id: row.id, version: version, width: width)
      guard next != shown || styleSerial != style.serial else { return }
      // The same content in a new style may take another height, which the table then asks.
      let isRestyle = next == shown
      guard let message = TranscriptTableTextMessage.make(row, ramp: style.ramp),
        let textStyle = style.style
      else {
        releaseContent()
        return
      }
      shown = next
      kind = .text(row.kind)
      styleSerial = style.serial
      self.message = message
      let documents = message.runs.map { run in
        MessageTextBlocksView.document(
          source: MessageTextSource(text: message.markdown, piece: run.id), blocks: run.blocks,
          linked: [], style: textStyle, links: nil)
      }
      let metrics = TranscriptTableTextMetrics(
        width: width, layoutWidth: style.layoutWidth, maxWidth: style.maxWidth)
      let textWidth =
        message.role == .answer ? metrics.columnWidth : metrics.promptWidth(style.layoutWidth)
      adopt(documents, width: textWidth)
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

    /// Shows `documents` laid out `width` wide: each as a raster drawn ahead when the surface
    /// draws runs ahead and one is kept, else as a live view borrowed from ``MessageTextViews``
    /// (and drawn ahead for next time). Runs that already show a document stay.
    private func adopt(_ documents: [MessageTextDocument], width: CGFloat) {
      var kept: [UInt64: TranscriptTableTextRun] = [:]
      for run in runs { kept[run.document.serial] = run }
      var adopted: [TranscriptTableTextRun] = []
      for document in documents {
        let raster = style.raster(for: document, width: width)
        if let run = kept.removeValue(forKey: document.serial) {
          if run.keeps(raster, width: width, style: style) {
            adopted.append(run)
            continue
          }
          run.release()
        }
        if let raster {
          let view = MessageTextRasterView(document: document, raster: raster)
          addSubview(view)
          adopted.append(.raster(view))
        } else {
          if style.drawsAhead, let rasterStyle = style.rasterStyle {
            MessageTextPrewarm.shared.draw(
              document, width: width, scale: style.scale, style: rasterStyle)
          }
          let view = MessageTextViews.shared.checkOut(document)
          addSubview(view)
          adopted.append(.live(view))
        }
      }
      for run in kept.values { run.release() }
      runs = adopted
    }

    /// Hands the text views back for the next cell that shows their documents.
    func releaseContent() {
      for run in runs { run.release() }
      runs = []
      shown = nil
      message = nil
    }

    var idealHeight: CGFloat { height }

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
      let gaps = message.runs.map(\.gapAbove)
      bubbleView.isHidden = true
      if let palette = style.palette, textWidth >= MessageTextContentView.minimumWidth {
        // The answers after this one lay out (and draw) ahead at this width.
        MessageTextPrewarm.shared.note(
          palette: palette, width: textWidth, scale: style.drawsAhead ? style.scale : 0,
          raster: style.drawsAhead ? style.rasterStyle : nil)
      }
      var bottom: CGFloat = 0
      for (index, run) in runs.enumerated() {
        bottom += gaps.indices.contains(index) ? gaps[index] : 0
        let size = run.size(for: textWidth, fillsWidth: true)
        run.view.frame = CGRect(
          x: metrics.columnX, y: bottom, width: size.width, height: size.height)
        bottom += size.height
      }
      // The footer follows the stack's spacing; without "Worked for" it takes no height and
      // the actions hang into the gap below the text.
      bottom += Theme.Spacing.small
      if let workedFor = message.decoration.workedFor {
        let label = workedLabel ?? makeWorkedLabel()
        label.stringValue = TurnElapsed.worked(workedFor)
        label.toolTip = message.decoration.timestamp.map {
          "Finished \(MessageTimestamp.format($0, now: Date()))"
        }
        let labelHeight = label.intrinsicContentSize.height.rounded(.up)
        label.frame = CGRect(
          x: metrics.columnX, y: bottom, width: metrics.columnWidth / 2, height: labelHeight)
        label.isHidden = false
        actionsTop = bottom
        actionsLineHeight = labelHeight
        bottom += labelHeight
      } else {
        workedLabel?.isHidden = true
        actionsTop = bottom - Theme.Spacing.small
        actionsLineHeight = 0
      }
      actionsTrailing = metrics.columnX + metrics.columnWidth
      return (bottom + Theme.Spacing.row).rounded(.up)
    }

    /// A user's prompt: its runs in a bubble that hugs them, at the column's trailing edge.
    private func layOutPrompt(
      metrics: TranscriptTableTextMetrics, textWidth: CGFloat, message: TranscriptTableTextMessage
    ) -> CGFloat {
      let gaps = message.runs.map(\.gapAbove)
      workedLabel?.isHidden = true
      var bottom: CGFloat = 0
      var used: CGFloat = 0
      var sizes: [CGSize] = []
      for run in runs {
        let size = run.size(for: textWidth, fillsWidth: false)
        sizes.append(size)
        used = max(used, size.width)
      }
      let bubbleWidth = used + 2 * Theme.Spacing.large
      let bubbleX = metrics.columnX + metrics.columnWidth - bubbleWidth
      bottom = Theme.Spacing.bubbleVertical
      for (index, run) in runs.enumerated() {
        bottom += gaps.indices.contains(index) ? gaps[index] : 0
        run.view.frame = CGRect(
          x: bubbleX + Theme.Spacing.large, y: bottom, width: sizes[index].width,
          height: sizes[index].height)
        bottom += sizes[index].height
      }
      let bubbleHeight = bottom + Theme.Spacing.bubbleVertical
      bubbleView.frame = CGRect(x: bubbleX, y: 0, width: bubbleWidth, height: bubbleHeight)
      bubbleView.color = style.bubble
      bubbleView.isHidden = false
      actionsTop = bubbleHeight
      actionsLineHeight = 0
      actionsTrailing = metrics.columnX + metrics.columnWidth
      return (bubbleHeight + Theme.Spacing.extraSmall + Theme.Spacing.row).rounded(.up)
    }

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

#endif
