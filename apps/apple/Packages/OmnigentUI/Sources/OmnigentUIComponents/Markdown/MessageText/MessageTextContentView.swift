#if os(macOS)
  import AppKit

  /// One document's text view, the layers behind its code blocks, tables, quotes and rules, and
  /// the controls over them. It lays out once per width and keeps that layout, so showing it
  /// again draws without typesetting. A table cell or a SwiftUI row hosts it through
  /// ``fittingSize(for:fillsWidth:)``.
  final class MessageTextContentView: NSView, NSTextViewDelegate {
    private(set) var document: MessageTextDocument
    /// The answer is still streaming: its text changes in place, and its view isn't kept for a
    /// row shown again.
    private(set) var isStreaming: Bool
    let textView: MessageTextKitView
    /// The stack laid out off the main actor that the text view shows, kept alive with it.
    private let prepared: MessageTextPreparedLayout?
    private let layers = MessageTextLayersView()
    /// Each block's control, by block.
    private(set) var chromeViews: [Int: NSView] = [:]
    private var measurements: [CGFloat: Measurement] = [:]
    /// The width the text is laid out at.
    private(set) var laidOutWidth: CGFloat?
    /// The width a bubble that hugs its text was measured at, kept while the bubble is narrower.
    private var huggedWidth: CGFloat?
    /// Layout passes run, for tests.
    private(set) var layoutPasses = 0
    private var foundLinkRects: [MessageTextLinkRect] = []
    private var linkRectsAreFound = false
    var openURL: (@MainActor (URL) -> Void)?
    /// Each code block's and table's paragraphs.
    lazy var spans = MessageTextBlockSpan.spans(in: document.text)
    /// Code blocks whose long lines scroll sideways instead of wrapping.
    private var unwrapped: Set<Int> = []
    /// Blocks whose text is hidden here, drawn by a copy that scrolls sideways.
    var hiddenBlocks: Set<Int> = []
    /// The copies drawing blocks that scroll sideways, by block.
    var overflows: [Int: MessageTextOverflowView] = [:]
    /// The elements accessibility reads, once built (``accessibilityChildren()``).
    var accessibilityItems: [Any] = []
    var accessibilityItemsAreBuilt = false

    /// A size at one width: how tall the text is and how wide its widest line.
    struct Measurement: Equatable {
      var height: CGFloat
      var usedWidth: CGFloat
    }

    /// Below this a proposed width only asks for a minimum; nothing is laid out.
    static let minimumWidth: CGFloat = 40
    /// The width an unconstrained proposal lays out at.
    static let unconstrainedWidth: CGFloat = 10_000
    init(document: MessageTextDocument, isStreaming: Bool = false) {
      self.document = document
      self.isStreaming = isStreaming
      // Text laid out off the main actor comes with its layout; anything else lays out here.
      prepared = document.takePreparedLayout()
      if let prepared {
        let frame = CGRect(x: 0, y: 0, width: prepared.width, height: 0)
        textView = MessageTextKitView(frame: frame, textContainer: prepared.container)
      } else {
        textView = MessageTextKitView(usingTextLayoutManager: true)
      }
      super.init(frame: .zero)
      configureTextView()
      addSubview(layers)
      addSubview(textView)
      // Accessibility reads the text as SwiftUI's renderer exposes it, not as one text area.
      textView.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private func configureTextView() {
      textView.configureForMessage(palette: document.palette)
      textView.delegate = self
      textView.linkAt = { [weak self] point in self?.link(at: point) }
      guard prepared == nil else { return }
      if let container = textView.textLayoutManager?.textContainer {
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
      }
      textView.textContentStorage?.textStorage?.setAttributedString(document.text)
    }

    // MARK: Size

    /// The size to show at a proposed width: the column's width (or the text's, for a bubble
    /// that hugs it) and the text's height there. Each width lays out once.
    func fittingSize(for proposed: CGFloat?, fillsWidth: Bool) -> CGSize {
      guard let proposed, proposed.isFinite else {
        // An ideal size: the text unwrapped, or as last laid out.
        let measured = measurement(for: laidOutWidth ?? Self.unconstrainedWidth)
        return CGSize(width: measured.usedWidth, height: measured.height)
      }
      guard proposed >= Self.minimumWidth else {
        return CGSize(width: max(proposed, 0), height: measurements.values.first?.height ?? 0)
      }
      let measured = measurement(for: proposed)
      if fillsWidth || document.hasWideBlocks {
        huggedWidth = nil
        return CGSize(width: proposed, height: measured.height)
      }
      huggedWidth = proposed
      return CGSize(width: min(proposed, measured.usedWidth), height: measured.height)
    }

    /// The text's size at `width`, laid out on first ask.
    func measurement(for width: CGFloat) -> Measurement {
      if let measured = measurements[width] { return measured }
      return layOut(width: width)
    }

    override func layout() {
      super.layout()
      let width = bounds.width
      guard width >= Self.minimumWidth else { return }
      // A bubble narrower than its measured width keeps that layout: its lines already fit.
      var layoutWidth = width
      if let huggedWidth, let measured = measurements[huggedWidth],
        measured.usedWidth <= width + 0.5
      {
        layoutWidth = huggedWidth
      }
      let measured: Measurement
      if laidOutWidth == layoutWidth, let kept = measurements[layoutWidth] {
        measured = kept
      } else {
        measured = layOut(width: layoutWidth)
      }
      let inset = document.topInset
      let frame = CGRect(
        x: 0, y: inset, width: width, height: max(bounds.height, measured.height) - inset)
      if textView.frame != frame { textView.frame = frame }
      if layers.frame != frame { layers.frame = frame }
    }

    /// Lays the whole text out `width` wide, then places its layers and controls.
    private func layOut(width: CGFloat) -> Measurement {
      guard let layout = textView.textLayoutManager, let container = layout.textContainer else {
        return Measurement(height: 0, usedWidth: 0)
      }
      layoutPasses += 1
      let overflowing = Set(
        spans.compactMap { block, span in
          span.overflows(width: width, wraps: !unwrapped.contains(block)) ? block : nil
        })
      hideText(of: overflowing)
      // The same size again would throw away a layout made off the main actor.
      let size = CGSize(width: width, height: MessageTextPreparedLayout.unlimitedHeight)
      if container.size != size { container.size = size }
      var collector = MessageTextLayerCollector(width: width)
      var height: CGFloat = 0
      var usedWidth: CGFloat = 0
      _ = layout.enumerateTextLayoutFragments(
        from: layout.documentRange.location, options: [.ensuresLayout]
      ) { fragment in
        let frame = fragment.layoutFragmentFrame
        height = max(height, frame.maxY)
        for line in fragment.textLineFragments {
          usedWidth = max(usedWidth, frame.minX + line.typographicBounds.maxX)
        }
        collector.add(fragment)
        return true
      }
      let shapes = collector.shapes
      layers.show(shapes, palette: document.palette)
      placeChrome(collector.chromeFrames)
      placeOverflows(overflowing, collector: collector, width: width)
      linkRectsAreFound = false
      laidOutWidth = width
      let measured = Measurement(
        height: (max(height, collector.bottom) + document.topInset).rounded(.up),
        usedWidth: usedWidth.rounded(.up))
      if measurements.count >= 4 { measurements.removeAll() }
      measurements[width] = measured
      return measured
    }

    private func placeChrome(_ frames: [Int: CGRect]) {
      for (block, frame) in frames {
        guard let chrome = document.chrome[block] else { continue }
        let view: NSView
        if let made = chromeViews[block] {
          view = made
        } else {
          view = makeChrome(chrome, block: block)
          chromeViews[block] = view
          addSubview(view)
          // The elements read a block's controls with its text.
          accessibilityItemsAreBuilt = false
        }
        view.frame = frame.offsetBy(dx: 0, dy: document.topInset)
      }
    }

    private func makeChrome(_ chrome: MessageTextChrome, block: Int) -> NSView {
      switch chrome {
      case .code(let code, let language):
        let header = MessageCodeHeaderView(
          language: language, code: code, palette: document.palette)
        header.wrapsLines = !unwrapped.contains(block)
        header.wrapChanged = { [weak self] wraps in self?.setWraps(wraps, block: block) }
        return header
      case .table(let table):
        return MessageTableControlsView(table: table, palette: document.palette)
      }
    }

    // MARK: Blocks that scroll sideways

    /// Wraps a code block's long lines, or has them scroll sideways; the text's height changes.
    func setWraps(_ wraps: Bool, block: Int) {
      guard wraps == unwrapped.contains(block) else { return }
      if wraps { unwrapped.remove(block) } else { unwrapped.insert(block) }
      forgetLayout()
    }

    /// Forgets every width's layout, after the text or its wrapping changed; whoever hosts the
    /// view asks its size again.
    private func forgetLayout() {
      measurements.removeAll()
      laidOutWidth = nil
      linkRectsAreFound = false
      accessibilityItemsAreBuilt = false
      needsLayout = true
      invalidateIntrinsicContentSize()
      // AppKit declares `superview` unowned(unsafe); it is only messaged here.
      unsafe superview?.invalidateIntrinsicContentSize()
    }

    // MARK: Links

    /// Each link's rectangle on each line, found once per layout when the pointer first asks.
    /// A link in a block drawn by a copy that scrolls is the copy's.
    var linkRects: [MessageTextLinkRect] {
      if linkRectsAreFound { return foundLinkRects }
      guard let layout = textView.textLayoutManager else { return [] }
      let hiddenRanges = hiddenBlocks.compactMap { spans[$0]?.range }
      let shown = document.links.filter { link in
        !hiddenRanges.contains { NSIntersectionRange($0, link.range).length > 0 }
      }
      foundLinkRects = MessageTextLinkRect.rects(in: layout, links: shown)
      linkRectsAreFound = true
      return foundLinkRects
    }

    /// The link at `point`, in the text view's coordinates.
    func link(at point: CGPoint) -> URL? {
      linkRects.first { $0.rect.contains(point) }?.url
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      guard let openURL,
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
      else { return false }
      openURL(url)
      return true
    }

  }

  extension MessageTextContentView {
    /// Shows `next`, the same answer further on, without making a new view: while it streams,
    /// only the text from the last block on changes, as the parser leaves closed blocks alone;
    /// once it settles, its links and math may change anywhere, so all of it is set again.
    func show(_ next: MessageTextDocument, isStreaming streaming: Bool) {
      guard next !== document, let storage = textView.textContentStorage?.textStorage else {
        return
      }
      // A run that didn't change keeps its layout.
      if streaming, next.endsOpen == document.endsOpen, next.text.string == document.text.string {
        document = next
        return
      }
      let start = streaming ? min(document.tailStart, storage.length) : 0
      let changed = Set(
        spans.compactMap { block, span in NSMaxRange(span.range) > start ? block : nil })
      for block in changed {
        chromeViews.removeValue(forKey: block)?.removeFromSuperview()
        overflows.removeValue(forKey: block)?.removeFromSuperview()
      }
      hiddenBlocks.subtract(changed)
      unwrapped.subtract(changed)
      let tail = NSRange(location: start, length: next.text.length - start)
      storage.beginEditing()
      storage.replaceCharacters(
        in: NSRange(location: start, length: storage.length - start),
        with: next.text.attributedSubstring(from: tail))
      storage.endEditing()
      document = next
      isStreaming = streaming
      spans = MessageTextBlockSpan.spans(in: next.text)
      forgetLayout()
    }
  }

  /// A link's rectangle on one line.
  struct MessageTextLinkRect: Equatable {
    var rect: CGRect
    var url: URL

    /// Each of `links`' rectangles on each line, as `layout` laid them out.
    static func rects(in layout: NSTextLayoutManager, links: [(range: NSRange, url: URL)])
      -> [Self]
    {
      guard let content = layout.textContentManager else { return [] }
      var rects: [Self] = []
      for link in links {
        guard
          let start = content.location(
            content.documentRange.location, offsetBy: link.range.location),
          let end = content.location(start, offsetBy: link.range.length),
          let range = NSTextRange(location: start, end: end)
        else { continue }
        layout.enumerateTextSegments(in: range, type: .standard) { _, frame, _, _ in
          rects.append(Self(rect: frame, url: link.url))
          return true
        }
      }
      return rects
    }
  }
#endif
