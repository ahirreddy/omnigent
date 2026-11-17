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
    private var styleSerial = -1
    private(set) var block: TranscriptTableCLIText?
    private(set) var document: CLITextDocument?
    /// The text, drawn or live.
    private(set) var run: TranscriptTableTextRun?
    let band = TranscriptTableCLIFillView()
    let decorations = TranscriptTableCLIDecorationsView()
    private let marker = TranscriptTableCLIDecorationsView()
    var cluster: TranscriptTableCLIClusterView?
    /// The text's frame and the column's trailing edge, where the actions sit.
    private(set) var textFrame = CGRect.zero
    private(set) var actionsTrailing: CGFloat = 0
    private var height: CGFloat = 0
    var isHovered = false
    var hoverArea: NSTrackingArea?

    init(style: TranscriptTableCLIStyle) {
      self.style = style
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
      guard let block = TranscriptTableCLIText.make(row, rendering: style.rendering),
        let document = style.document(for: block.spec, width: column.width)
      else {
        releaseContent()
        return
      }
      shown = next
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
      shown = nil
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
      case .footer:
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
      case .footer:
        setAccessibilityLabel(nil)
      }
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

  /// A view filled with one color: a prompt's band.
  final class TranscriptTableCLIFillView: NSView {
    var color = NSColor.clear {
      didSet { if color != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
      layer?.backgroundColor = color.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  /// What a CLI text draws beside its text, as Core Animation layers: rules and bars as fills,
  /// marker columns as drawings of their glyphs shared by every cell (``CLIGlyphDrawings``).
  final class TranscriptTableCLIDecorationsView: NSView {
    private let root = CALayer()
    /// The decorations shown, for tests.
    private(set) var shown: [CLITextDecoration] = []
    private var shownSerial = -1

    init() {
      super.init(frame: .zero)
      // A layer-hosting view: these layers are this view's own.
      root.isGeometryFlipped = true
      layer = root
      wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ decorations: [CLITextDecoration], style: TranscriptTableCLIStyle) {
      guard decorations != shown || style.serial != shownSerial else { return }
      shown = decorations
      shownSerial = style.serial
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      root.sublayers = decorations.compactMap { layer(for: $0, style: style) }
      CATransaction.commit()
    }

    private func layer(for decoration: CLITextDecoration, style: TranscriptTableCLIStyle)
      -> CALayer?
    {
      switch decoration {
      case .fill(let rect, let color, let opacity):
        let layer = CALayer()
        layer.frame = rect
        layer.backgroundColor = color.platformColor.withAlphaComponent(opacity).cgColor
        return layer
      case .markers(let glyph, let rect, let color):
        guard let text = style.text else { return nil }
        let metrics = text.metrics
        // A column one line tall at least, as a marker beside a text shows its first line.
        let lines = max(1, Int((rect.height / metrics.pitch).rounded(.up)))
        let scale = style.textStyle.scale > 0 ? style.textStyle.scale : 2
        let drawing = CLIGlyphDrawings.shared.drawing(
          CLIGlyphDrawings.Key(
            glyph: glyph, lines: lines, color: color, style: text, width: rect.width,
            scale: scale))
        let clip = CALayer()
        clip.frame = CGRect(
          x: rect.minX, y: rect.minY, width: rect.width,
          height: max(rect.height, metrics.lineHeight))
        clip.masksToBounds = true
        let image = CALayer()
        image.frame = CGRect(
          x: 0, y: drawing.topInset, width: drawing.width,
          height: max(0, drawing.size.height - drawing.topInset))
        image.contents = drawing.surface
        image.contentsScale = drawing.scale
        clip.addSublayer(image)
        return clip
      }
    }
  }

  /// Drawings of glyph columns (a quote's `>`s, a block's `•`), shared by every cell that shows
  /// one: drawn once per glyph, length, color, style and scale.
  @MainActor
  final class CLIGlyphDrawings {
    static let shared = CLIGlyphDrawings()

    /// What a drawing draws: `lines` lines of `glyph`, `width` wide.
    struct Key: Hashable {
      var glyph: String
      var lines: Int
      var color: SRGB
      var style: CLITextStyle
      var width: CGFloat
      var scale: CGFloat
    }

    private var drawings = BoundedCache<Key, MessageTextRaster>(limit: 256)

    func drawing(_ key: Key) -> MessageTextRaster {
      drawings.value(for: key) {
        let text = CLITextBuilder.glyphs(
          key.glyph, lines: key.lines, color: key.color, style: key.style)
        let clear = CGColor(gray: 0, alpha: 0)
        return MessageTextRaster.make(
          MessageTextRun(text: text, topInset: 0, links: []), width: max(key.width, 1),
          scale: key.scale,
          style: MessageTextRasterStyle(
            codeSurface: clear, codeHeader: clear, separator: clear, border: clear,
            quoteBar: clear, link: clear, codeRadius: 0))
      }
    }
  }
#endif
