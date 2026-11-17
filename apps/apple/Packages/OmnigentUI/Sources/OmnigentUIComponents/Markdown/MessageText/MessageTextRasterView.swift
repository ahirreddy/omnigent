#if os(macOS)
  import AppKit
  import IOSurface

  /// A run of message text drawn ahead (``MessageTextRaster``), shown as layer contents, so
  /// scrolling moves it and draws nothing. A press in the text lays a live text view
  /// (``MessageTextContentView``) over it for selecting and copying until that view gives up
  /// the keyboard; links take the pointing hand and open from the raster's link rectangles. A
  /// code block's or a table's controls are drawn at rest into the raster, and made as views
  /// only once the pointer reaches them (or a click or an assistive client does).
  final class MessageTextRasterView: NSView {
    let document: MessageTextDocument
    private(set) var raster: MessageTextRaster
    /// Whether the bitmap was let go while the view is off screen (``releaseBitmap()``).
    private(set) var isReleased = false
    private let image = MessageTextImageView()
    /// The controls made so far, by block.
    private(set) var chromeViews: [Int: NSView] = [:]
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// The key it was drawn under.
    var key: MessageTextRasterKey {
      MessageTextRasterKey(document: document.serial, width: raster.width, scale: raster.scale)
    }

    /// Shows `raster`, a drawing of this view's document. Controls the drawing leaves out are
    /// made now.
    func show(_ raster: MessageTextRaster) {
      self.raster = raster
      isReleased = false
      image.show(raster.surface, scale: raster.scale)
      for block in raster.chromeFrames.keys where !raster.drawnChrome.contains(block) {
        makeChrome(block)
      }
      needsLayout = true
    }

    /// Lets the bitmap go while the view is off screen; ``show(_:)`` takes one again.
    func releaseBitmap() {
      guard !isReleased, live == nil else { return }
      raster = raster.withoutBitmap()
      isReleased = true
      image.show(nil, scale: raster.scale)
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

    // MARK: Controls

    /// The control view for `block`, made now if it isn't yet.
    @discardableResult
    func makeChrome(_ block: Int) -> NSView? {
      if let made = chromeViews[block] { return made }
      guard let chrome = document.chrome[block], let frame = raster.chromeFrames[block] else {
        return nil
      }
      let view: NSView
      switch chrome {
      case .code(let code, let language):
        let header = MessageCodeHeaderView(
          language: language, code: code, palette: document.palette)
        // Long lines that scroll sideways need the live text, which the cell shows instead.
        header.wrapChanged = { [weak self] wraps in self?.wrapChanged?(block, wraps) }
        view = header
      case .table(let table):
        view = MessageTableControlsView(table: table, palette: document.palette)
      }
      view.frame = frame.offsetBy(dx: 0, dy: raster.topInset)
      view.isHidden = live != nil
      chromeViews[block] = view
      addSubview(view)
      return view
    }

    /// The block whose controls are under `point`, in the view's coordinates.
    private func chromeBlock(at point: CGPoint) -> Int? {
      let text = CGPoint(x: point.x, y: point.y - raster.topInset)
      return raster.chromeFrames.first { $0.value.contains(text) }?.key
    }

    // MARK: Pointer

    /// A point in the view, in the raster's text coordinates.
    private func textPoint(_ event: NSEvent) -> CGPoint {
      let point = convert(event.locationInWindow, from: nil)
      return CGPoint(x: point.x, y: point.y - raster.topInset)
    }

    override func mouseDown(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      // A press on a control drawn at rest goes to the control, made for it; one beside the
      // controls selects, as it would over them.
      if live == nil, let block = chromeBlock(at: point), let view = makeChrome(block) {
        view.layoutSubtreeIfNeeded()
        if let target = view.hitTest(point), target !== view {
          target.mouseDown(with: event)
          return
        }
      }
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
      // The pointer reached controls drawn at rest: the real ones take over, hover and all.
      if live == nil, let block = chromeBlock(at: convert(event.locationInWindow, from: nil)) {
        makeChrome(block)
      }
      setCursor(for: event)
    }

    override func cursorUpdate(with event: NSEvent) {
      setCursor(for: event)
    }

    private func setCursor(for event: NSEvent) {
      guard live == nil else { return }
      if chromeBlock(at: convert(event.locationInWindow, from: nil)) != nil {
        NSCursor.arrow.set()
        return
      }
      let isLink = raster.link(at: textPoint(event)) != nil
      (isLink ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }

    // MARK: Accessibility

    /// The text the drawing shows, for a reader of shown text such as a test's; `nil` while the
    /// live text lies over it, which reads itself.
    @objc var drawnText: String? {
      live == nil ? document.text.string : nil
    }

    override func isAccessibilityElement() -> Bool { false }

    // The live text's elements, as SwiftUI exposes the message's: an assistive client reads
    // the text the drawing shows, laid over it while the run shows. AppKit's signature makes
    // them optional.
    // swiftlint:disable:next discouraged_optional_collection
    override func accessibilityChildren() -> [Any]? {
      activate().accessibilityChildren()
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
