#if os(macOS)
  import AppKit
  import SwiftUI

  /// A cell that draws a settled CLI block in AppKit, as ``CLIBlockView`` draws it: its text as
  /// TextKit text laid out once per width (``CLITextDocument``) and shown as a drawing made
  /// ahead or a live text view, the gutter's marker, a prompt's band, and the actions hover
  /// reveals. Its height is SwiftUI's for the same block, known with no SwiftUI pass.
  final class TranscriptTableCLICell: NSView, TranscriptTableCell {
    private(set) var shown: TranscriptTableShown?
    private(set) var kind: TranscriptTableCellKind?
    var idealSizeChanged: ((any TranscriptTableCell) -> Void)?

    let style: TranscriptTableCLIStyle
    /// The tool work the reader opened, shared by the table's cells.
    let expansions: CLIWorkExpansions
    private var styleSerial = -1
    /// The row shown, to show again once the reader opens or closes its work.
    private(set) var shownRow: TranscriptTableRow?
    private(set) var block: TranscriptTableCLIText?
    private(set) var document: CLITextDocument?
    /// The text, drawn or live.
    private(set) var run: TranscriptTableTextRun?
    let band = TranscriptTableCLIFillView()
    let decorations = TranscriptTableCLIDecorationsView()
    private let marker = TranscriptTableCLIDecorationsView()
    var cluster: TranscriptTableCLIClusterView?
    /// The tables wider than the text, each in a copy that scrolls sideways over its rows, and
    /// the document they were made for.
    var overflowViews: [MessageTextOverflowView] = []
    weak var overflowsDocument: CLITextDocument?
    /// Tool work's region elements, and the document they were made for.
    var workElements: (document: CLITextDocument?, elements: [TranscriptTableCLIRegionElement]) =
      (nil, [])
    /// The text's frame and the column's trailing edge, where the actions sit.
    private(set) var textFrame = CGRect.zero
    private(set) var actionsTrailing: CGFloat = 0
    private var height: CGFloat = 0
    var isHovered = false
    var hoverArea: NSTrackingArea?

    init(style: TranscriptTableCLIStyle, expansions: CLIWorkExpansions = CLIWorkExpansions()) {
      self.style = style
      self.expansions = expansions
      super.init(frame: .zero)
      band.isHidden = true
      addSubview(band)
      addSubview(decorations)
      addSubview(marker)
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
      guard next != shown || styleSerial != style.serial || awaitsRaster else { return }
      if next == shown, styleSerial == style.serial, takeBitmapBack() { return }
      let isRestyle = next == shown
      let column = style.column(width: width)
      guard let palette = style.text?.palette,
        let block = TranscriptTableCLIText.make(
          row, rendering: style.rendering, palette: palette, expansions: expansions),
        let document = style.document(for: block.spec, width: column.width)
      else {
        releaseContent()
        return
      }
      shown = next
      shownRow = row
      kind = .cliText(row.kind)
      styleSerial = style.serial
      self.block = block
      self.document = document
      if let context = style.prewarmContext(width: column.width) {
        // The texts after this one lay out (and draw) ahead at this width.
        CLITextPrewarm.shared.note(context)
      }
      adopt(document)
      let openURL = (style.environment.values?.openURL).map { open in
        { @MainActor (url: URL) in open(url) }
      }
      run?.setOpenURL(openURL)
      let previous = height
      height = layOut(block, document: document, column: column, width: width)
      identify(block)
      refreshActions()
      if isRestyle, abs(previous - height) >= 0.5 { idealSizeChanged?(self) }
    }

    /// Shows `document` as its drawing when one is kept or it is short enough to draw now, else
    /// as a live view while the prewarm draws it. A run already showing it stays.
    private func adopt(_ document: CLITextDocument) {
      let raster = style.raster(for: document)
      if let run, run.document === document.text {
        if run.keeps(raster, width: document.width, style: style.textStyle) { return }
      }
      run?.release()
      run = makeRun(document, raster: raster)
    }

    /// A new run for `document`: its raster (drawn now when the text is short), else a live
    /// view, drawn ahead for next time.
    private func makeRun(_ document: CLITextDocument, raster: MessageTextRaster?)
      -> TranscriptTableTextRun
    {
      var raster = raster
      let scale = style.textStyle.scale
      if raster == nil, style.drawsAhead, let rasterStyle = style.rasterStyle,
        document.text.text.length < TranscriptTableTextCell.drawsNowBelow
      {
        let drawn = MessageTextRaster.make(
          document.text.run, width: document.width, scale: scale, style: rasterStyle)
        MessageTextRasters.shared.store(
          drawn,
          for: MessageTextRasterKey(
            document: document.text.serial, width: document.width, scale: scale))
        raster = drawn
      }
      if let raster {
        let view = MessageTextRasterView(document: document.text, raster: raster)
        addSubview(view, positioned: .below, relativeTo: decorations)
        return .raster(view)
      }
      if style.drawsAhead, let rasterStyle = style.rasterStyle {
        MessageTextPrewarm.shared.draw(
          document.text, width: document.width, scale: scale, style: rasterStyle)
      }
      let view = MessageTextViews.shared.checkOut(document.text)
      addSubview(view, positioned: .below, relativeTo: decorations)
      return .live(view)
    }

    /// Whether the text shows live while texts draw ahead, or let its bitmap go: its drawing
    /// may have arrived since.
    private var awaitsRaster: Bool {
      guard style.drawsAhead, let run else { return false }
      switch run {
      case .live: return true
      case .raster(let view): return view.isReleased
      case .block: return false
      }
    }

    /// Hands the text view back for the next cell that shows its document.
    func releaseContent() {
      run?.release()
      run = nil
      removeOverflows()
      shown = nil
      shownRow = nil
      block = nil
      document = nil
      cluster?.isHidden = true
    }

    var idealHeight: CGFloat { height }

    /// Its height is the text's, known at show: nothing reports later.
    func settle() {}

    // MARK: Layout

    /// Places the text, its marker, decorations and band; returns the row's height.
    private func layOut(
      _ block: TranscriptTableCLIText, document: CLITextDocument,
      column: TranscriptTableCLIColumn, width: CGFloat
    ) -> CGFloat {
      let cli = style.text?.palette ?? .fallback
      let lineHeight = style.text?.metrics.lineHeight ?? 16
      let top: CGFloat = block.kind == .prompt ? CLIMetrics.bandPadding : 0
      textFrame = CGRect(x: column.leading, y: top, width: column.width, height: document.height)
      run?.view.frame = textFrame
      decorations.frame = textFrame
      decorations.show(document.decorations, style: style)
      placeOverflows(document)
      actionsTrailing = column.leading + column.width
      let character = (style.text?.points ?? 13) * CLIFontSize.characterRatio
      let markerWidth = character * CGFloat(CLIMetrics.markerColumns)
      marker.frame = CGRect(
        x: column.leading - markerWidth, y: top, width: markerWidth, height: document.height)
      switch block.kind {
      case .answer:
        band.isHidden = true
        marker.show(
          [
            .markers(
              CLIBullet.glyph, CGRect(x: 0, y: 0, width: markerWidth, height: lineHeight),
              cli.bullet)
          ],
          style: style)
        return (document.height + CLIMetrics.blockGap).rounded(.up)
      case .prompt:
        let bandHeight = document.height + 2 * CLIMetrics.bandPadding
        band.frame = CGRect(x: 0, y: 0, width: width, height: bandHeight)
        band.color = cli.band.platformColor
        band.isHidden = false
        marker.show(
          [
            .markers(
              "\u{203A}", CGRect(x: 0, y: 0, width: markerWidth, height: lineHeight), cli.prompt)
          ],
          style: style)
        return (bandHeight + CLIMetrics.blockGap).rounded(.up)
      case .footer, .work:
        band.isHidden = true
        marker.show([], style: style)
        return (document.height + CLIMetrics.blockGap).rounded(.up)
      }
    }

    /// The identifiers and labels the CLI views give the block.
    private func identify(_ block: TranscriptTableCLIText) {
      guard let message = block.message else {
        setAccessibilityElement(false)
        setAccessibilityIdentifier(nil)
        setAccessibilityLabel(nil)
        return
      }
      setAccessibilityElement(true)
      setAccessibilityIdentifier("message-\(message.id)")
      switch block.kind {
      case .prompt:
        setAccessibilityLabel(
          block.decoration.showsAvatar ? "\(message.author ?? "Someone") said" : "You said")
      case .answer:
        setAccessibilityLabel(nil)
        run?.view.setAccessibilityIdentifier("message-text-\(message.id)")
      case .footer, .work:
        setAccessibilityLabel(nil)
      }
    }

    /// The reader opened or closed `id`'s work, or collapsed its group: shown again, at its
    /// new height.
    func toggle(_ id: String, collapsing: Bool = false) {
      guard let row = shownRow, let shown else { return }
      if collapsing { expansions.toggleCollapsed(id) } else { expansions.toggle(id) }
      let previous = height
      self.shown = nil
      show(row, version: shown.version, width: shown.width)
      if abs(previous - height) >= 0.5 { idealSizeChanged?(self) }
    }

    // MARK: Drawings

    /// Lets the drawn text's bitmap go once the cell leaves the table: the rasters' cache keeps
    /// it under its memory budget, and showing the cell again takes it back.
    func releaseBitmaps() {
      if case .raster(let view)? = run { view.releaseBitmap() }
    }

    /// Takes the drawn text's bitmap back from the rasters' cache.
    /// - Returns: Whether the text shows its drawing again.
    private func takeBitmapBack() -> Bool {
      guard case .raster(let view)? = run else { return false }
      guard view.isReleased else { return true }
      guard let raster = MessageTextRasters.shared.raster(for: view.key) else { return false }
      view.show(raster)
      return true
    }

    /// `block`'s height at `width`, as a cell shows it, from its built document: a row far from
    /// view is measured with no views. `nil` before the style is known.
    static func measuredHeight(
      of block: TranscriptTableCLIText, style: TranscriptTableCLIStyle, width: CGFloat
    ) -> CGFloat? {
      let column = style.column(width: width)
      guard let document = style.document(for: block.spec, width: column.width) else {
        return nil
      }
      let bandPadding = block.kind == .prompt ? 2 * CLIMetrics.bandPadding : 0
      return (document.height + bandPadding + CLIMetrics.blockGap).rounded(.up)
    }
  }
#endif
