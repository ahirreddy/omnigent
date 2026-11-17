#if os(iOS)
  import SwiftUI
  import UIKit

  /// The style iPhone and iPad text rows (``TranscriptCollectionTextView``) draw in, read from
  /// the transcript's environment: the reading ramp at its text size, the built text's style and
  /// palette, the column, the bubble's color and the scale runs are drawn at. ``serial`` rises
  /// when any of it changes, and rows showing the old style show again. It also says which
  /// messages a text row draws, and builds, draws and measures their runs.
  @MainActor
  final class TranscriptCollectionTextStyle {
    let environment: TranscriptTableEnvironment
    private(set) var ramp = TypeRamp(body: TypeRamp.defaultBody)
    private(set) var style: MessageTextStyle?
    private(set) var palette: MessageTextPalette?
    private(set) var layoutWidth = LayoutWidth.compact
    private(set) var maxWidth = Theme.transcriptWidth
    private(set) var bubble = UIColor.clear
    /// The bubble's color as resolved, which compares by value where `UIColor`s may not.
    private var bubbleColor: Color.Resolved?
    /// The "Worked for" line's caption font at the transcript's text size, and its height.
    private(set) var captionFont = UIFont.preferredFont(forTextStyle: .caption1)
    private(set) var captionHeight: CGFloat = 0
    /// Whether settled messages draw as text: the TextKit renderer, chat style, rich output.
    private(set) var isEnabled = false
    /// The display's pixels per point, which runs draw at.
    private(set) var scale: CGFloat = 0
    /// The layers' colors for drawn runs.
    private(set) var rasterStyle: MessageTextRasterStyle?
    private(set) var serial = 0
    /// Runs drawn on the main actor because no drawing was kept when their row showed.
    private(set) var drawnNow = 0
    /// What each row was worked out to show, by id: its content version and the message a text
    /// row draws, `nil` for a row SwiftUI keeps.
    private var messages: [String: (version: Int, message: TranscriptTableTextMessage?)] = [:]

    /// A drawing taller than this many pixels is more than a layer shows: its row stays SwiftUI's.
    static let tallestDrawing: CGFloat = 16_384

    init(environment: TranscriptTableEnvironment) {
      self.environment = environment
    }

    /// Reads the environment again.
    /// - Returns: Whether the style changed.
    @discardableResult
    func refresh() -> Bool {
      guard let values = environment.values else { return false }
      return refresh(from: values)
    }

    /// Takes the transcript's environment `values`, without reading ``environment``: SwiftUI's
    /// update that hands them over would come to depend on what it writes.
    /// - Returns: Whether the style changed.
    @discardableResult
    func refresh(from values: EnvironmentValues) -> Bool {
      let appearance = values.transcriptAppearance
      let traits = UITraitCollection(
        preferredContentSizeCategory: UIContentSizeCategory(values.dynamicTypeSize))
      // As ``ReadingProseStyle`` scales the chat text size with Dynamic Type.
      let percent = UIFontMetrics(forTextStyle: .body).scaledValue(
        for: 100, compatibleWith: traits)
      let ramp = TypeRamp(body: CGFloat(appearance.chatFontSize) * percent / 100)
      var reading = values
      reading.typeRamp = ramp
      let style = MessageTextStyle(environment: reading, code: MessageCodeFont())
      let isEnabled =
        values.messageTextRenderer == .textKit && !appearance.isCLI
        && appearance.outputRendering == .rich
      let maxWidth = appearance.contentWidth.maxWidth
      let bubbleColor = ThemeColor.userBubble.resolve(in: values).resolve(in: values)
      let captionFont = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
      guard
        style != self.style || ramp != self.ramp || isEnabled != self.isEnabled
          || values.layoutWidth != layoutWidth || maxWidth != self.maxWidth
          || bubbleColor != self.bubbleColor
          || captionFont.pointSize != self.captionFont.pointSize
      else { return false }
      if style != self.style {
        let palette = MessageTextPalette(style)
        self.palette = palette
        rasterStyle = MessageTextRasterStyle(
          codeSurface: palette.codeSurface.cgColor, codeHeader: palette.hover.cgColor,
          separator: palette.separator.cgColor, border: palette.border.cgColor,
          quoteBar: palette.tertiary.cgColor, link: palette.link.cgColor,
          codeRadius: Theme.Radius.large)
      }
      self.style = style
      self.ramp = ramp
      self.isEnabled = isEnabled
      layoutWidth = values.layoutWidth
      self.maxWidth = maxWidth
      self.bubbleColor = bubbleColor
      bubble = UIColor(Color(bubbleColor))
      self.captionFont = captionFont
      captionHeight = captionFont.lineHeight.rounded(.up)
      scale = style.scale
      messages = [:]
      serial += 1
      return true
    }

    /// Where a row `width` wide puts its message's column.
    func metrics(width: CGFloat) -> TranscriptTableTextMetrics {
      TranscriptTableTextMetrics(width: width, layoutWidth: layoutWidth, maxWidth: maxWidth)
    }

    // MARK: Messages

    /// The message a text row draws for `row`, or `nil` when the row stays SwiftUI's; worked
    /// out once per content version.
    func message(for row: TranscriptTableRow, version: Int) -> TranscriptTableTextMessage? {
      guard isEnabled else { return nil }
      if let known = messages[row.id], known.version == version { return known.message }
      let made = TranscriptTableTextMessage.make(row, ramp: ramp).flatMap {
        Self.draws($0) ? $0 : nil
      }
      messages[row.id] = (version, made)
      return made
    }

    /// Keeps row `id` SwiftUI's until the style changes: its text can't be drawn at the width
    /// (a table wider than the column, a drawing taller than a layer shows).
    func keepHosted(_ id: String, version: Int) {
      messages[id] = (version, nil)
    }

    /// Whether a text row draws all of `message`: one run of text, in a prompt's bubble or over
    /// an answer's "Worked for" line. Blocks only SwiftUI draws, the parts beside the text, an
    /// author's avatar and the latest answer's action row keep the row SwiftUI's.
    static func draws(_ message: TranscriptTableTextMessage) -> Bool {
      guard !message.decoration.showsActions, message.avatar == nil,
        message.belowBubble == nil, message.promptFold == nil, message.entries.count == 1,
        case .piece(let piece) = message.entries[0], case .text = piece.content
      else { return false }
      return true
    }

    /// The document of `message`'s text run: built once per text, style, linked paths and
    /// typeset math, or taken from the prewarm.
    /// - Parameters:
    ///   - message: The message.
    ///   - linked: The URLs of the paths the message cites, empty while none is known.
    /// - Returns: The document; `nil` before the style is known.
    func document(for message: TranscriptTableTextMessage, linked: [URL?] = [])
      -> MessageTextDocument?
    {
      guard let palette, let run = message.runs.first,
        let key = documentKey(for: message, linked: linked)
      else { return nil }
      let math = Self.typesetMath(run.inlineMath, ramp: palette.style.ramp)
      let links = environment.values?.workspaceFileLinks
      return MessageTextDocuments.shared.document(for: key) {
        if let prepared = MessageTextRunPrewarm.preparedDocument(for: key) { return prepared }
        var blocks = run.blocks
        if !linked.isEmpty, let links { blocks = blocks.map { $0.linking(with: links) } }
        var builder = MessageTextBuilder(palette: palette)
        builder.typesetMath = math
        let built = builder.document(blocks)
        let prewarm = message.role == .answer ? MessageTextRunPrewarm.answers : .prompts
        prewarm.keep(built, for: key)
        return built
      }
    }

    /// What `message`'s text run's document is built from, with the inline math typeset so far.
    func documentKey(for message: TranscriptTableTextMessage, linked: [URL?] = [])
      -> MessageTextDocumentKey?
    {
      guard let style, let run = message.runs.first else { return nil }
      let math = Self.typesetMath(run.inlineMath, ramp: style.ramp)
      return MessageTextDocumentKey(
        text: message.markdown, piece: run.id, style: style, linked: linked,
        math: math.keys.sorted())
    }

    /// Whether `message`'s document is built, here or by a prewarm, with nothing built now.
    func isBuilt(_ message: TranscriptTableTextMessage) -> Bool {
      guard let key = documentKey(for: message) else { return false }
      return MessageTextDocuments.shared.cached(key) != nil
        || MessageTextRunPrewarm.preparedDocument(for: key) != nil
    }

    /// The width `message`'s text lays out at in a row `width` wide.
    func textWidth(of message: TranscriptTableTextMessage, width: CGFloat) -> CGFloat {
      message.textWidth(metrics(width: width), layoutWidth: layoutWidth)
    }

    // MARK: Drawings and sizes

    func rasterKey(for document: MessageTextDocument, width: CGFloat) -> MessageTextRasterKey {
      MessageTextRasterKey(document: document.serial, width: width, scale: scale)
    }

    /// The drawing kept for `document` at `width`, else one drawn now on the main actor.
    func raster(for document: MessageTextDocument, width: CGFloat) -> MessageTextRaster? {
      guard scale > 0, let rasterStyle else { return nil }
      let key = rasterKey(for: document, width: width)
      if let kept = MessageTextRasters.shared.raster(for: key) { return kept }
      drawnNow += 1
      let raster = MessageTextRaster.make(
        document.run, width: width, scale: scale, style: rasterStyle)
      MessageTextRasters.shared.store(raster, for: key)
      MessageTextSizes.shared.store(raster.size, document: document.serial, width: width)
      return raster
    }

    /// `document`'s size `width` wide: as laid out ahead or drawn, else laid out now.
    func size(of document: MessageTextDocument, width: CGFloat) -> MessageTextSize {
      if let size = MessageTextSizes.shared.size(document: document.serial, width: width) {
        return size
      }
      let size = MessageTextSize.measure(document.run, width: width)
      MessageTextSizes.shared.store(size, document: document.serial, width: width)
      return size
    }

    /// Whether `document` draws whole at `width`: no table wider than the column, and not
    /// taller than a layer shows, as far as its size is known.
    func canDraw(_ document: MessageTextDocument, width: CGFloat) -> Bool {
      let overflows = MessageTextBlockSpan.spans(in: document.text).values.contains {
        $0.overflows(width: width, wraps: true)
      }
      guard !overflows else { return false }
      let size = MessageTextSizes.shared.size(document: document.serial, width: width)
      return (size?.height ?? 0) * scale <= Self.tallestDrawing
    }

    /// The run's size in its row: a prompt's hugs its text, unless a block in it spans the
    /// column.
    func runSize(
      _ size: MessageTextSize, of document: MessageTextDocument,
      role: TranscriptTableTextMessage.Role, textWidth: CGFloat
    ) -> CGSize {
      let hugs = role == .user && !document.hasWideBlocks
      return CGSize(width: hugs ? min(textWidth, size.usedWidth) : textWidth, height: size.height)
    }

    /// Where a text row puts `message`'s parts at `width`, its run `size` large.
    func frames(of message: TranscriptTableTextMessage, runSize size: CGSize, width: CGFloat)
      -> TranscriptCollectionTextFrames
    {
      TranscriptCollectionTextFrames(
        role: message.role, runSize: size, metrics: metrics(width: width),
        workedHeight: message.role == .answer
          ? message.decoration.workedFor.map { _ in captionHeight } : nil)
    }

    /// `message`'s height in a text row `width` wide, from its run's laid-out size, with no
    /// view: `nil` when the row can't draw it.
    /// - Parameters:
    ///   - message: The message.
    ///   - width: The row's width.
    ///   - draws: A run not laid out yet is drawn now, for a row about to show, rather than only
    ///     laid out: it is then laid out once.
    /// - Returns: The height.
    func measuredHeight(
      of message: TranscriptTableTextMessage, width: CGFloat, draws: Bool = false
    ) -> CGFloat? {
      let textWidth = self.textWidth(of: message, width: width)
      guard let document = document(for: message), canDraw(document, width: textWidth) else {
        return nil
      }
      let known = MessageTextSizes.shared.size(document: document.serial, width: textWidth)
      let drawn = known == nil && draws ? raster(for: document, width: textWidth)?.size : nil
      let size = known ?? drawn ?? self.size(of: document, width: textWidth)
      guard size.height * scale <= Self.tallestDrawing else { return nil }
      let run = runSize(size, of: document, role: message.role, textWidth: textWidth)
      return frames(of: message, runSize: run, width: width).height
    }

    // MARK: Inline math

    /// A run's inline math typeset at `ramp`'s size so far, by TeX: from the renderer's cache,
    /// kept where the prewarm reads it too.
    static func typesetMath(_ math: [String], ramp: TypeRamp) -> [String: RenderedRichBlock] {
      var typeset: [String: RenderedRichBlock] = [:]
      for tex in math {
        let request = mathRequest(tex, ramp: ramp)
        if let image = RichBlockRenderer.shared.cached(request) {
          MessageTextTypesetMath.shared.store(image, for: request)
          typeset[tex] = image
        } else if let image = MessageTextTypesetMath.shared.image(for: request) {
          typeset[tex] = image
        }
      }
      return typeset
    }

    /// Inline math at `ramp`'s size, as the SwiftUI markdown asks for it.
    static func mathRequest(_ tex: String, ramp: TypeRamp) -> RichBlockRequest {
      RichBlockRequest(kind: .math(display: false, size: ramp.body), source: tex)
    }

    // MARK: Prewarm

    /// Whether the prewarms build messages: they know the width and style to.
    var hasPrewarms: Bool { isEnabled && MessageTextRunPrewarm.answers.context != nil }

    /// Has the prewarms build answers at the column's width and prompts at their bubbles', in a
    /// row `width` wide.
    func notePrewarms(width: CGFloat) {
      guard isEnabled, let palette, let rasterStyle, scale > 0, width > 0 else { return }
      let metrics = metrics(width: width)
      MessageTextRunPrewarm.answers.note(
        MessageTextRunPrewarm.Context(
          palette: palette, width: metrics.columnWidth, scale: scale, raster: rasterStyle))
      MessageTextRunPrewarm.prompts.note(
        MessageTextRunPrewarm.Context(
          palette: palette, width: metrics.promptWidth(layoutWidth), scale: scale,
          raster: rasterStyle))
    }
  }

  /// Where a text row puts a message from its run's size: an answer's run down the column with
  /// its "Worked for" line under it, a prompt's in a bubble that hugs it at the column's
  /// trailing edge, as ``MessageRowView`` stacks them on touch, where a hidden action row takes
  /// no space.
  struct TranscriptCollectionTextFrames: Equatable {
    var run: CGRect = .zero
    /// A prompt's bubble.
    var bubble: CGRect?
    /// An answer's "Worked for" line.
    var worked: CGRect?
    /// The message's own frame in the column: what a linked message's flash tints.
    var content: CGRect = .zero
    var height: CGFloat = 0

    init(
      role: TranscriptTableTextMessage.Role, runSize: CGSize,
      metrics: TranscriptTableTextMetrics, workedHeight: CGFloat?
    ) {
      switch role {
      case .answer:
        run = CGRect(origin: CGPoint(x: metrics.columnX, y: 0), size: runSize)
        var bottom = runSize.height
        if let workedHeight {
          bottom += Theme.Spacing.small
          worked = CGRect(
            x: metrics.columnX, y: bottom, width: metrics.columnWidth, height: workedHeight)
          bottom += workedHeight
        }
        content = CGRect(x: metrics.columnX, y: 0, width: metrics.columnWidth, height: bottom)
        height = (bottom + Theme.Spacing.row).rounded(.up)
      case .user:
        let bubbleWidth = runSize.width + 2 * Theme.Spacing.large
        let bubbleX = metrics.columnX + metrics.columnWidth - bubbleWidth
        run = CGRect(
          origin: CGPoint(x: bubbleX + Theme.Spacing.large, y: Theme.Spacing.bubbleVertical),
          size: runSize)
        let bubbleHeight = runSize.height + 2 * Theme.Spacing.bubbleVertical
        bubble = CGRect(x: bubbleX, y: 0, width: bubbleWidth, height: bubbleHeight)
        content = CGRect(
          x: metrics.columnX, y: 0, width: metrics.columnWidth, height: bubbleHeight)
        height = (bubbleHeight + Theme.Spacing.row).rounded(.up)
      }
    }
  }
#endif
