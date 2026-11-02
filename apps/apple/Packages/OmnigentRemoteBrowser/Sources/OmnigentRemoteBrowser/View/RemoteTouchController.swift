#if os(iOS)
  import OmnigentCoreFFI
  import QuartzCore
  import UIKit

  /// Touch on a remote page (design doc sections 16.3–16.5):
  ///
  /// - Tap clicks; a two-finger tap right-clicks; double tap zooms (not in Mobile Size).
  /// - Pinch zooms the video locally; one finger pans the zoomed video first and scrolls the
  ///   page with the rest; two fingers always scroll the page.
  /// - Scrolling is wheel deltas with `UIScrollView` momentum computed here, and the video
  ///   rubber-bands at the page's edges (from the host's scroll reports).
  /// - A drag that starts on a desktop page's scroll bar grabs it (a mouse drag); a drag on a
  ///   mobile page's scroll indicator scrubs; long press selects a word and dragging extends the
  ///   selection, then the edit menu appears (`RemoteTouchController+Selection`).
  final class RemoteTouchController: NSObject {
    private enum PanMode {
      case scroll
      /// Grabbing the page's scroll bar; `armed` once the button is down.
      case mouseDrag(armed: Bool)
      case scrub(indicator: RemoteScrollIndicator, metrics: RemoteScrollMetrics, sent: Double)
    }

    weak var view: RemoteBrowserView?
    var store: RemoteBrowserStore? { view?.store }
    let tap = UITapGestureRecognizer()
    let doubleTap = UITapGestureRecognizer()
    let twoFingerTap = UITapGestureRecognizer()
    let pinch = UIPinchGestureRecognizer()
    let pan = UIPanGestureRecognizer()
    let longPress = UILongPressGestureRecognizer()
    let hover = UIHoverGestureRecognizer()
    var editMenu: UIEditMenuInteraction?
    var menuAnchor: CGPoint?

    private var panMode: PanMode?
    private var lastPanPoint = CGPoint.zero
    private var momentum: RemoteMomentum?
    /// The finger's distance past the page's edge, before rubber-band resistance.
    private var overscroll = CGPoint.zero
    private var springFrom: (overscroll: CGPoint, start: CFTimeInterval)?
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    init(view: RemoteBrowserView) {
      self.view = view
      super.init()
      doubleTap.numberOfTapsRequired = 2
      twoFingerTap.numberOfTouchesRequired = 2
      pan.maximumNumberOfTouches = 2
      pan.allowedScrollTypesMask = .all
      longPress.minimumPressDuration = 0.45
      let actions: [(UIGestureRecognizer, Selector)] = [
        (tap, #selector(handleTap(_:))), (doubleTap, #selector(handleDoubleTap(_:))),
        (twoFingerTap, #selector(handleTwoFingerTap(_:))), (pinch, #selector(handlePinch(_:))),
        (pan, #selector(handlePan(_:))), (longPress, #selector(handleLongPress(_:))),
        (hover, #selector(handleHover(_:))),
      ]
      for (recognizer, action) in actions {
        recognizer.addTarget(self, action: action)
        recognizer.delegate = self
        view.addGestureRecognizer(recognizer)
      }
      let menu = UIEditMenuInteraction(delegate: self)
      view.addInteraction(menu)
      editMenu = menu
    }

    // MARK: Mapping

    func css(_ point: CGPoint, clamped: Bool = false) -> CGPoint? {
      view?.displayGeometry?.cssPoint(for: point, clamped: clamped)
    }

    var fit: CGRect { view?.geometry?.contentRect ?? .zero }
    var bounds: CGSize { view?.bounds.size ?? .zero }

    func mouse(
      _ kind: MouseKind, _ point: CGPoint, button: MouseButton? = nil, clicks: UInt8 = 1,
      held: RemoteModifiers = [], deltaX: Double = 0, deltaY: Double = 0
    ) {
      store?.send(
        MouseInput(
          kind: kind, x: point.x, y: point.y, button: button, clicks: button == nil ? 0 : clicks,
          modifiers: held.rawValue, dx: deltaX, dy: deltaY))
    }

    private func click(_ point: CGPoint, button: MouseButton) {
      let bit = RemoteInputMapping.buttonBit(button)
      mouse(.move, point)
      mouse(.down, point, button: button, held: bit)
      mouse(.up, point, button: button)
    }

    // MARK: Taps

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
      guard let view else { return }
      editMenu?.dismissMenu()
      view.lastTapAt = .now
      if !view.keyboardProxy.isFirstResponder { view.becomeFirstResponder() }
      guard let point = css(recognizer.location(in: view)) else { return }
      click(point, button: .left)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
      guard let view else { return }
      view.zoom.toggle(at: recognizer.location(in: view), fit: fit, bounds: bounds)
      view.relayout(animated: true)
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
      guard let view, let point = css(recognizer.location(in: view)) else { return }
      click(point, button: .right)
    }

    // MARK: Pinch

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      guard let view else { return }
      let anchor = recognizer.location(in: view)
      switch recognizer.state {
      case .began:
        stopMomentum()
      case .changed:
        view.zoom.zoom(
          by: recognizer.scale, anchor: anchor, fit: fit, bounds: bounds, elastic: true)
        recognizer.scale = 1
        view.relayout()
      case .ended, .cancelled, .failed:
        view.zoom.settle(anchor: anchor, fit: fit, bounds: bounds)
        view.relayout(animated: true)
      default:
        break
      }
    }

  }

  // MARK: Pan, scrolling and momentum

  extension RemoteTouchController {
    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
      guard let view else { return }
      let location = recognizer.location(in: view)
      switch recognizer.state {
      case .began: panBegan(recognizer, at: location)
      case .changed: panChanged(recognizer, at: location)
      case .ended, .cancelled, .failed: panEnded(recognizer, at: location)
      default: break
      }
    }

    private func panBegan(_ recognizer: UIPanGestureRecognizer, at location: CGPoint) {
      guard let view, let store else { return }
      stopMomentum()
      springFrom = nil
      let translation = recognizer.translation(in: view)
      let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
      recognizer.setTranslation(.zero, in: view)
      lastPanPoint = location
      panMode = beginMode(at: start, store: store)
      if case .mouseDrag = panMode, let point = css(start, clamped: true) {
        grabScrollBar(at: point)
      } else {
        scroll(by: translation, at: location, oneFinger: recognizer.numberOfTouches < 2)
      }
    }

    private func panChanged(_ recognizer: UIPanGestureRecognizer, at location: CGPoint) {
      guard let view else { return }
      let delta = recognizer.translation(in: view)
      recognizer.setTranslation(.zero, in: view)
      lastPanPoint = location
      switch panMode {
      case .mouseDrag(armed: true): continueDrag(to: location)
      case .mouseDrag(armed: false): break
      case .scrub: scrub(to: location)
      default: scroll(by: delta, at: location, oneFinger: recognizer.numberOfTouches < 2)
      }
    }

    private func panEnded(_ recognizer: UIPanGestureRecognizer, at location: CGPoint) {
      switch panMode {
      case .mouseDrag(let armed):
        if armed, let point = css(location, clamped: true) { mouse(.up, point, button: .left) }
      case .scrub:
        break
      default:
        let velocity = recognizer.velocity(in: view)
        if recognizer.state == .ended, hypot(velocity.x, velocity.y) > 60 {
          momentum = RemoteMomentum(velocity: velocity)
        }
        startTicking()
      }
      panMode = nil
    }

    private func beginMode(at start: CGPoint, store: RemoteBrowserStore) -> PanMode {
      guard store.canSendInput, let view, let geometry = view.displayGeometry,
        let point = geometry.cssPoint(for: start)
      else { return .scroll }
      if store.viewportMode.hasPageScrollBars,
        RemoteTouchRegions.isOnScrollBar(
          css: point, viewport: geometry.viewport, pointsPerCSS: geometry.scale,
          scroll: store.snapshot.scroll)
      {
        return .mouseDrag(armed: false)
      }
      if store.viewportMode.isMobile, let metrics = store.snapshot.scroll,
        let indicator = view.scrollIndicator, indicator.grabs(start)
      {
        view.flashIndicator()
        return .scrub(indicator: indicator, metrics: metrics, sent: 0)
      }
      return .scroll
    }

    /// Presses on the scroll bar. Overlay scroll bars (macOS hosts) only take a drag while
    /// shown, so a one-pixel scroll shows them first.
    private func grabScrollBar(at point: CGPoint) {
      mouse(.wheel, point, deltaY: 1)
      Task { [weak self] in
        do {
          try await Task.sleep(for: .milliseconds(60))
        } catch {
          return
        }
        guard let self, case .mouseDrag(armed: false) = self.panMode else { return }
        self.mouse(.move, point)
        self.mouse(.down, point, button: .left, held: .leftButton)
        self.panMode = .mouseDrag(armed: true)
        self.continueDrag(to: self.lastPanPoint)
      }
    }

    private func continueDrag(to location: CGPoint) {
      guard let point = css(location, clamped: true) else { return }
      mouse(.move, point, held: .leftButton)
    }

    private func scrub(to location: CGPoint) {
      guard case .scrub(let indicator, let metrics, let sent) = panMode,
        let point = css(location, clamped: true)
      else { return }
      let target = indicator.scrollOffset(thumbCenterY: location.y, metrics: metrics)
      let delta = target - (metrics.y + sent)
      guard abs(delta) >= 1 else { return }
      mouse(.wheel, point, deltaY: delta)
      panMode = .scrub(indicator: indicator, metrics: metrics, sent: sent + delta)
      view?.flashIndicator()
    }

    // MARK: Scrolling

    /// Moves the zoomed video (one finger) and scrolls the page with the rest; past the page's
    /// edge, the video rubber-bands instead.
    private func scroll(by delta: CGPoint, at location: CGPoint, oneFinger: Bool) {
      guard let view, let store else { return }
      if pinch.state == .began || pinch.state == .changed {
        // Fingers moving during a pinch move the zoomed video, as in Safari.
        _ = view.zoom.pan(by: delta, fit: fit, bounds: bounds)
        view.relayout()
        return
      }
      var remaining = delta
      if oneFinger, view.zoom.isZoomed {
        remaining = view.zoom.pan(by: delta, fit: fit, bounds: bounds)
      }
      if store.canSendInput, let geometry = view.displayGeometry {
        scrollPage(by: absorbOverscroll(remaining), at: location, geometry: geometry)
      }
      updateRubberBand()
      view.relayout()
    }

    /// Sends what the page can take as a wheel event; the rest stretches the rubber band.
    private func scrollPage(
      by movement: CGPoint, at location: CGPoint, geometry: RemoteViewportGeometry
    ) {
      let edges = RemoteScrollPhysics.canScroll(by: movement, metrics: store?.snapshot.scroll)
      let wheel = CGPoint(x: edges.x ? movement.x : 0, y: edges.y ? movement.y : 0)
      let over = CGPoint(x: movement.x - wheel.x, y: movement.y - wheel.y)
      overscroll = CGPoint(x: overscroll.x + over.x, y: overscroll.y + over.y)
      if over.x != 0 { momentum?.stop(vertical: false) }
      if over.y != 0 { momentum?.stop(vertical: true) }
      guard wheel != .zero, let point = geometry.cssPoint(for: location, clamped: true) else {
        return
      }
      // A finger moving down scrolls up: the DOM's deltaY is negative.
      mouse(
        .wheel, point, deltaX: -geometry.cssLength(wheel.x), deltaY: -geometry.cssLength(wheel.y))
    }

    /// A finger moving back toward the page first undoes the rubber band.
    private func absorbOverscroll(_ delta: CGPoint) -> CGPoint {
      func axis(_ over: inout CGFloat, _ amount: CGFloat) -> CGFloat {
        guard over != 0, amount != 0, (over > 0) != (amount > 0) else { return amount }
        let taken = min(abs(over), abs(amount))
        over -= over > 0 ? taken : -taken
        return amount + (amount > 0 ? -taken : taken)
      }
      var horizontal = overscroll.x
      var vertical = overscroll.y
      let rest = CGPoint(x: axis(&horizontal, delta.x), y: axis(&vertical, delta.y))
      overscroll = CGPoint(x: horizontal, y: vertical)
      return rest
    }

    private func updateRubberBand() {
      guard let view else { return }
      view.rubberBand = CGPoint(
        x: RemoteScrollPhysics.rubberBand(overscroll.x, dimension: bounds.width),
        y: RemoteScrollPhysics.rubberBand(overscroll.y, dimension: bounds.height))
    }

    // MARK: Momentum and spring

    private func startTicking() {
      if momentum == nil, overscroll != .zero {
        springFrom = (overscroll, CACurrentMediaTime())
      }
      guard momentum != nil || springFrom != nil, displayLink == nil else { return }
      let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
      lastTick = CACurrentMediaTime()
      link.add(to: .main, forMode: .common)
      displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
      let now = link.timestamp
      let interval = min(now - lastTick, 0.05)
      lastTick = now
      if var current = momentum {
        let moved = current.step(interval)
        momentum = current.isFinished ? nil : current
        scroll(by: moved, at: lastPanPoint, oneFinger: true)
        if momentum == nil, overscroll != .zero {
          springFrom = (overscroll, now)
        }
        view?.flashIndicator()
      } else if let spring = springFrom {
        let elapsed = now - spring.start
        overscroll = CGPoint(
          x: RemoteScrollPhysics.springBack(spring.overscroll.x, elapsed: elapsed),
          y: RemoteScrollPhysics.springBack(spring.overscroll.y, elapsed: elapsed))
        if overscroll == .zero { springFrom = nil }
        updateRubberBand()
        view?.relayout()
      }
      if momentum == nil, springFrom == nil {
        link.invalidate()
        displayLink = nil
      }
    }

    func stopMomentum() {
      momentum = nil
      displayLink?.invalidate()
      displayLink = nil
    }
  }
#endif
