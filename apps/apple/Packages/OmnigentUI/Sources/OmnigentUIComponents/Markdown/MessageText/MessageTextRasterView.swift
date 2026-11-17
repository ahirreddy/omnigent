#if os(macOS)
  import AppKit
  import IOSurface

  /// A run of message text drawn ahead (``MessageTextRaster``), shown as layer contents, so
  /// scrolling moves it and draws nothing. A press in the text lays a live text view
  /// (``MessageTextContentView``) over it for selecting and copying until that view gives up
  /// the keyboard; links take the pointing hand and open from the raster's link rectangles; a
  /// code block's or a table's controls are light views over their bands.
  final class MessageTextRasterView: NSView {
    let document: MessageTextDocument
    private(set) var raster: MessageTextRaster
    private let image = MessageTextImageView()
    private var chromeViews: [Int: NSView] = [:]
    /// The text view laid over the raster while the reader selects.
    private(set) var live: MessageTextContentView?
    var openURL: (@MainActor (URL) -> Void)?
    /// A code block's Wrap was turned on or off, by block.
    var wrapChanged: ((Int, Bool) -> Void)?
    private var pointerArea: NSTrackingArea?
    private var pressedLink: URL?

    init(document: MessageTextDocument, raster: MessageTextRaster) {
      self.document = document
      self.raster = raster
      super.init(frame: .zero)
      addSubview(image)
      show(raster)
      setAccessibilityElement(true)
      setAccessibilityRole(.staticText)
      setAccessibilityValue(document.text.string)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Shows `raster`, a drawing of this view's document.
    func show(_ raster: MessageTextRaster) {
      self.raster = raster
      image.show(raster.surface, scale: raster.scale)
      for (block, frame) in raster.chromeFrames {
        guard chromeViews[block] == nil, let chrome = document.chrome[block] else { continue }
        let view = makeChrome(chrome, block: block)
        chromeViews[block] = view
        addSubview(view)
        view.frame = frame.offsetBy(dx: 0, dy: raster.topInset)
      }
      needsLayout = true
    }

    override func layout() {
      super.layout()
      let frame = CGRect(
        x: 0, y: raster.topInset, width: raster.width,
        height: max(0, raster.size.height - raster.topInset))
      if image.frame != frame { image.frame = frame }
      for (block, view) in chromeViews {
        guard let chromeFrame = raster.chromeFrames[block] else { continue }
        view.frame = chromeFrame.offsetBy(dx: 0, dy: raster.topInset)
      }
      if let live, live.frame != bounds { live.frame = bounds }
    }

    private func makeChrome(_ chrome: MessageTextChrome, block: Int) -> NSView {
      switch chrome {
      case .code(let code, let language):
        let header = MessageCodeHeaderView(
          language: language, code: code, palette: document.palette)
        // Long lines that scroll sideways need the live text, which the cell shows instead.
        header.wrapChanged = { [weak self] wraps in self?.wrapChanged?(block, wraps) }
        return header
      case .table(let table):
        return MessageTableControlsView(table: table, palette: document.palette)
      }
    }

    // MARK: Pointer

    /// A point in the view, in the raster's text coordinates.
    private func textPoint(_ event: NSEvent) -> CGPoint {
      let point = convert(event.locationInWindow, from: nil)
      return CGPoint(x: point.x, y: point.y - raster.topInset)
    }

    override func mouseDown(with event: NSEvent) {
      if let url = raster.link(at: textPoint(event)) {
        pressedLink = url
        return
      }
      // The live view takes the press, and the drag that follows selects.
      activate().textView.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
      defer { pressedLink = nil }
      guard let url = pressedLink, raster.link(at: textPoint(event)) == url else { return }
      openURL?(url)
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      // One area that follows the visible rect, so scrolling rebuilds nothing.
      guard pointerArea == nil else { return }
      let area = NSTrackingArea(
        rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
        owner: self)
      addTrackingArea(area)
      pointerArea = area
    }

    override func mouseMoved(with event: NSEvent) {
      super.mouseMoved(with: event)
      setCursor(for: event)
    }

    override func cursorUpdate(with event: NSEvent) {
      setCursor(for: event)
    }

    private func setCursor(for event: NSEvent) {
      guard live == nil else { return }
      let isLink = raster.link(at: textPoint(event)) != nil
      (isLink ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }

    // MARK: Live text

    /// The live text view over the raster, laid over it now if it is not yet.
    @discardableResult
    func activate() -> MessageTextContentView {
      if let live { return live }
      let view = MessageTextViews.shared.checkOut(document)
      view.openURL = openURL
      view.frame = bounds
      // After the change of first responder settles, not inside it.
      view.textView.resigned = { [weak self] in
        MainRunLoop.perform { MainActor.assumeIsolated { self?.deactivate() } }
      }
      addSubview(view)
      live = view
      image.isHidden = true
      for chrome in chromeViews.values { chrome.isHidden = true }
      return view
    }

    /// Takes the live view away once it gives up the keyboard; the raster shows again.
    func deactivate() {
      guard let live, unsafe window?.firstResponder !== live.textView else { return }
      live.textView.resigned = nil
      live.removeFromSuperview()
      MessageTextViews.shared.checkIn(live)
      self.live = nil
      image.isHidden = false
      for chrome in chromeViews.values { chrome.isHidden = false }
    }
  }

  /// A bitmap shown as its layer's contents: the view never draws.
  final class MessageTextImageView: NSView {
    private var image: IOSurface?
    private var scale: CGFloat = 1

    init() {
      super.init(frame: .zero)
      wantsLayer = true
      layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ image: IOSurface?, scale: CGFloat) {
      self.image = image
      self.scale = scale
      updateLayer()
    }

    override func updateLayer() {
      guard let layer else { return }
      if (layer.contents as AnyObject?) !== (image as AnyObject?) { layer.contents = image }
      if layer.contentsScale != scale { layer.contentsScale = scale }
    }
  }
#endif
