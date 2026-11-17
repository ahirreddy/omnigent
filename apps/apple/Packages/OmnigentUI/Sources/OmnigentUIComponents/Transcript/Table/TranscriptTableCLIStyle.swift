#if os(macOS)
  import AppKit
  import SwiftUI

  /// Whether CLI rows draw in CLI text cells while the TextKit renderer is on:
  /// `omnigent:transcript-cli-text`. `text` (the default) draws settled CLI messages and turn
  /// footers as TextKit text; `hosted` keeps every CLI row SwiftUI's.
  nonisolated enum TranscriptTableCLITextSetting: String, Sendable {
    case text
    case hosted

    static let key = "omnigent:transcript-cli-text"

    /// The setting this launch's defaults choose.
    static let launchValue = Self(defaults: .standard)

    init(defaults: UserDefaults) {
      self = defaults.string(forKey: Self.key).flatMap(Self.init(rawValue:)) ?? .text
    }
  }

  /// Where a CLI row's text goes in a cell: the column ``TranscriptColumn`` gives CLI rows, the
  /// gutter wide enough for the markers that hang in it.
  struct TranscriptTableCLIColumn: Equatable {
    var leading: CGFloat
    var width: CGFloat
  }

  /// The style CLI text cells draw in, read from the transcript's environment: the CLI font and
  /// palette, the output rendering, the column, and the documents' and drawings' styles.
  /// ``serial`` rises when any of it changes, and the cells showing the old style lay out again.
  @MainActor
  final class TranscriptTableCLIStyle {
    let environment: TranscriptTableEnvironment
    /// The chat text style, for the window's scale, the surface and a live resize.
    let textStyle: TranscriptTableTextStyle
    private(set) var text: CLITextStyle?
    private(set) var rendering = OutputRendering.styled
    /// Whether CLI rows draw in CLI text cells: the TextKit renderer, CLI style, Plain or Styled.
    private(set) var isEnabled = false
    private(set) var layoutWidth = LayoutWidth.regular
    private(set) var maxWidth = CGFloat.infinity
    /// The documents' style: the links in the CLI's color.
    private(set) var palette: MessageTextPalette?
    private(set) var rasterStyle: MessageTextRasterStyle?
    private var ownSerial = 0
    let setting: TranscriptTableCLITextSetting

    init(
      environment: TranscriptTableEnvironment, textStyle: TranscriptTableTextStyle,
      setting: TranscriptTableCLITextSetting = .launchValue
    ) {
      self.environment = environment
      self.textStyle = textStyle
      self.setting = setting
    }

    /// Rises with this style's changes and the chat style's (the scale, a live resize).
    var serial: Int { ownSerial &* 1_000_003 &+ textStyle.serial }

    /// Reads the environment again.
    /// - Returns: Whether the style changed.
    @discardableResult
    func refresh() -> Bool {
      guard let values = environment.values else { return false }
      let appearance = values.transcriptAppearance
      let isEnabled =
        setting == .text && values.messageTextRenderer == .textKit && appearance.isCLI
        && appearance.outputRendering != .rich
      let text = CLITextStyle(
        points: CGFloat(appearance.fontSize), scale: max(1, values.displayScale),
        palette: values.cliPalette)
      let maxWidth = appearance.contentWidth.maxWidth
      guard
        text != self.text || isEnabled != self.isEnabled
          || appearance.outputRendering != rendering || values.layoutWidth != layoutWidth
          || maxWidth != self.maxWidth
      else { return false }
      if text != self.text || palette == nil {
        var style = MessageTextStyle(environment: values, code: MessageCodeFont())
        style.link = text.palette.link.color.resolve(in: values)
        palette = MessageTextPalette(style)
        let clear = CGColor(gray: 0, alpha: 0)
        rasterStyle = MessageTextRasterStyle(
          codeSurface: clear, codeHeader: clear, separator: clear, border: clear,
          quoteBar: clear, link: text.palette.link.platformColor.cgColor, codeRadius: 0)
      }
      self.text = text
      self.isEnabled = isEnabled
      rendering = appearance.outputRendering
      layoutWidth = values.layoutWidth
      self.maxWidth = maxWidth
      ownSerial += 1
      return true
    }

    /// The column in a cell `width` wide, as ``TranscriptColumn`` lays a CLI row out. During a
    /// live resize a column narrower than its limit snaps down, as the chat's does.
    func column(width: CGFloat) -> TranscriptTableCLIColumn {
      let points = text?.points ?? CGFloat(TranscriptAppearance.defaultFontSize)
      let markers = points * CLIFontSize.characterRatio * CGFloat(CLIMetrics.markerColumns)
      let minimum = layoutWidth == .compact ? CLIMetrics.compactGutter : CLIMetrics.gutter
      let gutter = max(minimum, markers + Theme.Spacing.extraSmall)
      let rail = layoutWidth == .regular ? TurnRail.restingEdge : 0
      let limit = layoutWidth == .compact ? CGFloat.infinity : maxWidth
      var content = max(0, min(limit, width - 2 * gutter - rail))
      let snap = TranscriptTableTextStyle.liveResizeSnap
      if textStyle.isLiveResizing, content < limit {
        content = (content / snap).rounded(.down) * snap
      }
      let padded = content + 2 * gutter + rail
      let leading = max(0, (width - padded) / 2) + gutter + rail
      let scale = max(1, textStyle.scale)
      return TranscriptTableCLIColumn(leading: (leading * scale).rounded() / scale, width: content)
    }

    /// Whether texts are drawn ahead, at a known scale.
    var drawsAhead: Bool { textStyle.drawsAhead && rasterStyle != nil }

    /// The document for `spec` at `width`: built already, by a cell or the prewarm, or now.
    func document(for spec: CLITextSpec, width: CGFloat) -> CLITextDocument? {
      guard let text, let palette, width > 0 else { return nil }
      return CLITextDocuments.shared.document(
        for: CLITextKey(spec: spec, style: text, width: width), palette: palette)
    }

    /// The document for `spec` at `width`, if one is built.
    func builtDocument(for spec: CLITextSpec, width: CGFloat) -> CLITextDocument? {
      guard let text else { return nil }
      return CLITextDocuments.shared.cached(CLITextKey(spec: spec, style: text, width: width))
    }

    /// The raster kept for `document`, if one was drawn at the window's scale.
    func raster(for document: CLITextDocument) -> MessageTextRaster? {
      guard drawsAhead else { return nil }
      return MessageTextRasters.shared.raster(
        for: MessageTextRasterKey(
          document: document.text.serial, width: document.width, scale: textStyle.scale))
    }

    /// The prewarm's context for texts `width` wide, drawn ahead when runs are.
    func prewarmContext(width: CGFloat) -> CLITextPrewarm.Context? {
      guard let text, let palette else { return nil }
      return CLITextPrewarm.Context(
        style: text, width: width, palette: palette, scale: drawsAhead ? textStyle.scale : 0,
        raster: drawsAhead ? rasterStyle : nil)
    }
  }
#endif
