#if os(macOS)
  import AppKit
  import SwiftUI

  /// The style text cells draw in, read from the transcript's environment: the reading ramp, the
  /// built text's style and palette, the column and the bubble's color. ``serial`` rises when
  /// any of it changes, and the cells showing the old style lay out again.
  @MainActor
  final class TranscriptTableTextStyle {
    let environment: TranscriptTableEnvironment
    private(set) var ramp = TypeRamp(body: TypeRamp.defaultBody)
    private(set) var style: MessageTextStyle?
    private(set) var palette: MessageTextPalette?
    private(set) var layoutWidth = LayoutWidth.regular
    private(set) var maxWidth = Theme.transcriptWidth
    private(set) var bubble = NSColor.clear
    /// The transcript's own text size, outside the reading ramp: a Worked fold's title.
    private(set) var labelSize = TypeRamp.defaultBody
    /// The session's commands and skills, whose leading one a prompt tints.
    private(set) var promptCommands: [SlashCommand] = []
    /// Whether settled messages draw in text cells: the TextKit renderer, chat style, rich
    /// output.
    private(set) var isEnabled = false
    /// Live text views, or runs drawn ahead.
    var surface = MessageTextSurface.launchValue
    /// The window's pixels per point, which runs are drawn ahead at.
    private(set) var scale: CGFloat = 0
    /// The layers' colors and the controls at rest for runs drawn ahead.
    private(set) var rasterStyle: MessageTextRasterStyle?
    private(set) var serial = 0
    /// Documents that show as live text, not drawn ahead: the reader set a code block's long
    /// lines scrolling sideways, which a drawing can't.
    var liveDocuments: Set<UInt64> = []

    init(environment: TranscriptTableEnvironment) {
      self.environment = environment
    }

    /// Reads the environment again.
    /// - Returns: Whether the style changed.
    @discardableResult
    func refresh() -> Bool {
      guard let values = environment.values else { return false }
      let appearance = values.transcriptAppearance
      let ramp = TypeRamp(body: CGFloat(appearance.chatFontSize))
      var reading = values
      reading.typeRamp = ramp
      let style = MessageTextStyle(environment: reading, code: MessageCodeFont())
      let isEnabled =
        values.messageTextRenderer == .textKit && !appearance.isCLI
        && appearance.outputRendering == .rich
      let maxWidth = appearance.contentWidth.maxWidth
      let bubble = NSColor(Color(ThemeColor.userBubble.resolve(in: values).resolve(in: values)))
      let labelSize = values.typeRamp.body
      guard
        style != self.style || ramp != self.ramp || isEnabled != self.isEnabled
          || values.layoutWidth != layoutWidth || maxWidth != self.maxWidth
          || bubble != self.bubble || labelSize != self.labelSize
          || values.promptCommands != promptCommands
      else { return false }
      if style != self.style {
        palette = MessageTextPalette(style)
        makeRasterStyle()
      }
      self.style = style
      self.ramp = ramp
      self.isEnabled = isEnabled
      layoutWidth = values.layoutWidth
      self.maxWidth = maxWidth
      self.bubble = bubble
      self.labelSize = labelSize
      promptCommands = values.promptCommands
      serial += 1
      return true
    }

    /// Takes the window's scale.
    /// - Returns: Whether it changed.
    @discardableResult
    func setScale(_ scale: CGFloat) -> Bool {
      guard scale > 0, scale != self.scale else { return false }
      self.scale = scale
      makeRasterStyle()
      serial += 1
      return true
    }

    /// The raster style for the palette and scale, its controls stamped at that scale.
    private func makeRasterStyle() {
      guard let palette else { return }
      let stamps =
        surface == .raster
        ? MessageTextChromeStamps.stamps(for: palette, scale: scale)
        : MessageTextChromeStamps.Stamps()
      rasterStyle = MessageTextRasterStyle(
        codeSurface: palette.codeSurface.cgColor, codeHeader: palette.hover.cgColor,
        separator: palette.separator.cgColor, border: palette.border.cgColor,
        quoteBar: palette.tertiary.cgColor, link: palette.link.cgColor,
        codeRadius: Theme.Radius.large, codeChrome: stamps.code, tableChrome: stamps.table)
    }

    /// Whether the window is being resized live: text lays out at column widths snapped to
    /// ``liveResizeSnap`` meanwhile, and exactly once the resize ends.
    private(set) var isLiveResizing = false
    static let liveResizeSnap: CGFloat = 32
    /// While a column slides beside the transcript, the widest the chat column lays out at: its
    /// width as the slide began, so a widening slide lays no text out again until it ends.
    var columnCeiling: CGFloat?

    /// Starts or ends a live resize. `restyles` lays the cells out again in the new style, which
    /// an end needs only when the snapped widths differed from the exact ones.
    /// - Returns: Whether that changed.
    @discardableResult
    func setLiveResizing(_ resizing: Bool, restyles: Bool = true) -> Bool {
      guard resizing != isLiveResizing else { return false }
      isLiveResizing = resizing
      if restyles { serial += 1 }
      return true
    }

    /// Where a cell `width` wide puts its message's column.
    func metrics(width: CGFloat) -> TranscriptTableTextMetrics {
      guard isLiveResizing else { return exactMetrics(width: width) }
      return TranscriptTableTextMetrics(
        width: width, layoutWidth: layoutWidth, maxWidth: maxWidth, snap: Self.liveResizeSnap,
        ceiling: columnCeiling ?? .infinity)
    }

    /// The column at `width` with no live resize or slide under way.
    func exactMetrics(width: CGFloat) -> TranscriptTableTextMetrics {
      TranscriptTableTextMetrics(width: width, layoutWidth: layoutWidth, maxWidth: maxWidth)
    }

    /// Whether runs are drawn ahead, at a known scale.
    var drawsAhead: Bool { surface == .raster && scale > 0 && rasterStyle != nil }

    /// The raster kept for `document` at `width`, if one was drawn and can show it.
    func raster(for document: MessageTextDocument, width: CGFloat) -> MessageTextRaster? {
      guard drawsAhead else { return nil }
      let raster = MessageTextRasters.shared.raster(
        for: MessageTextRasterKey(document: document.serial, width: width, scale: scale))
      return raster?.overflows == false ? raster : nil
    }
  }

  /// One piece of a text cell: a run of text as a live TextKit view or a drawing made ahead,
  /// or a block only SwiftUI draws, hosted on its own.
  enum TranscriptTableTextRun {
    case live(MessageTextContentView)
    case raster(MessageTextRasterView)
    case block(TranscriptTableBlockView)

    var view: NSView {
      switch self {
      case .live(let view): view
      case .raster(let view): view
      case .block(let view): view
      }
    }

    /// The text it shows; `nil` for a hosted block.
    var document: MessageTextDocument? {
      switch self {
      case .live(let view): view.document
      case .raster(let view): view.document
      case .block: nil
      }
    }

    /// The run's size at a proposed width: the width when it fills it, else its text's.
    func size(for width: CGFloat, fillsWidth: Bool) -> CGSize {
      switch self {
      case .live(let view):
        return view.fittingSize(for: width, fillsWidth: fillsWidth)
      case .raster(let view):
        let size = view.raster.size
        let hugs = !fillsWidth && !view.document.hasWideBlocks
        return CGSize(width: hugs ? min(width, size.usedWidth) : width, height: size.height)
      case .block(let view):
        return CGSize(width: width, height: view.idealHeight)
      }
    }

    /// Whether the run can keep showing its document at `width`: a raster of that width and
    /// scale while runs draw ahead, a live view until a raster arrives or while the reader is
    /// selecting in it. A newer raster replaces the one shown.
    func keeps(_ raster: MessageTextRaster?, width: CGFloat, style: TranscriptTableTextStyle)
      -> Bool
    {
      switch self {
      case .raster(let view):
        if let raster {
          if raster !== view.raster { view.show(raster) }
          return true
        }
        return style.drawsAhead && !view.isReleased && view.raster.width == width
          && view.raster.scale == style.scale
      case .live(let view):
        return unsafe raster == nil || view.window?.firstResponder === view.textView
      case .block:
        return true
      }
    }

    /// Opens links with `openURL`.
    func setOpenURL(_ openURL: (@MainActor (URL) -> Void)?) {
      switch self {
      case .live(let view): view.openURL = openURL
      case .raster(let view): view.openURL = openURL
      case .block: break
      }
    }

    /// Hands a live view back for the next run that shows its document.
    func release() {
      view.removeFromSuperview()
      switch self {
      case .live(let view): MessageTextViews.shared.checkIn(view)
      case .raster(let view): view.deactivate()
      case .block(let view): view.sizeChanged = nil
      }
    }
  }
#endif
