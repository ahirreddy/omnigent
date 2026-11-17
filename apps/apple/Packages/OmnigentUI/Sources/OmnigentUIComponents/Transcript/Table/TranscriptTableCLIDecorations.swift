#if os(macOS)
  import AppKit
  import SwiftUI

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
      case .region:
        return nil
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
