#if os(macOS)
  import AppKit

  /// One document's text view, the layers behind its code blocks, tables, quotes and rules, and
  /// the controls over them. It lays out once per width and keeps that layout, so showing it
  /// again draws without typesetting. A table cell or a SwiftUI row hosts it through
  /// ``fittingSize(for:fillsWidth:)``.
  final class MessageTextContentView: NSView, NSTextViewDelegate {
    let document: MessageTextDocument
    let textView: MessageTextKitView
    /// The stack laid out off the main actor that the text view shows, kept alive with it.
    private let prepared: MessageTextPreparedLayout?
    private let layers = MessageTextLayersView()
    private var chromeViews: [Int: NSView] = [:]
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

    /// A size at one width: how tall the text is and how wide its widest line.
    struct Measurement: Equatable {
      var height: CGFloat
      var usedWidth: CGFloat
    }

    /// Below this a proposed width only asks for a minimum; nothing is laid out.
    static let minimumWidth: CGFloat = 40
    /// The width an unconstrained proposal lays out at.
    static let unconstrainedWidth: CGFloat = 10_000
    init(document: MessageTextDocument) {
      self.document = document
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private func configureTextView() {
      textView.isEditable = false
      textView.isSelectable = true
      textView.isRichText = true
      textView.importsGraphics = false
      textView.drawsBackground = false
      textView.textContainerInset = .zero
      textView.isVerticallyResizable = false
      textView.isHorizontallyResizable = false
      // Find stays the window's: one message's own find bar or panel would search only it.
      textView.usesFindBar = false
      textView.usesFindPanel = false
      textView.isIncrementalSearchingEnabled = false
      textView.displaysLinkToolTips = false
      textView.isAutomaticLinkDetectionEnabled = false
      textView.linkTextAttributes = [
        .foregroundColor: document.palette.link,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
        .cursor: NSCursor.pointingHand,
      ]
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
          view = makeChrome(chrome)
          chromeViews[block] = view
          addSubview(view)
        }
        view.frame = frame.offsetBy(dx: 0, dy: document.topInset)
      }
    }

    private func makeChrome(_ chrome: MessageTextChrome) -> NSView {
      switch chrome {
      case .code(let code, let language):
        MessageCodeHeaderView(
          label: CodeLanguageName.label(for: language), code: code, palette: document.palette)
      case .table(let table):
        MessageTableControlsView(table: table, palette: document.palette)
      }
    }

    // MARK: Links

    /// Each link's rectangle on each line, found once per layout when the pointer first asks.
    var linkRects: [MessageTextLinkRect] {
      if linkRectsAreFound { return foundLinkRects }
      var rects: [MessageTextLinkRect] = []
      guard let layout = textView.textLayoutManager, let content = layout.textContentManager
      else {
        return rects
      }
      for link in document.links {
        guard
          let start = content.location(
            content.documentRange.location, offsetBy: link.range.location),
          let end = content.location(start, offsetBy: link.range.length),
          let range = NSTextRange(location: start, end: end)
        else { continue }
        layout.enumerateTextSegments(in: range, type: .standard) { _, frame, _, _ in
          rects.append(MessageTextLinkRect(rect: frame, url: link.url))
          return true
        }
      }
      foundLinkRects = rects
      linkRectsAreFound = true
      return rects
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

  /// A link's rectangle on one line.
  struct MessageTextLinkRect: Equatable {
    var rect: CGRect
    var url: URL
  }
#endif
