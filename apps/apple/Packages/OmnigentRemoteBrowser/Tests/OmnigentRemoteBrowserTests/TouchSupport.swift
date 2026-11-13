#if os(iOS)
  import Foundation
  import OmnigentCoreFFI
  import OmnigentViewTesting
  import UIKit

  @testable import OmnigentRemoteBrowser

  /// A page in control, on a window, with a touch controller whose fingers the test moves. The
  /// view is 1000 x 1000 points and the page 1000 x 500 CSS px at one point per pixel, so in
  /// the desktop modes the page is y 250 to 750 and the rest is letterbox.
  @MainActor
  struct TouchPage {
    let hosted: HostedStore
    let view: RemoteBrowserView
    let screen: InProcessWindow
    let touch: RemoteTouchController
    let pinch = ScriptedPinch()
    let pan = ScriptedPan()
    let longPress = ScriptedLongPress()
    let editMenu: RecordingEditMenu

    init(
      _ snapshot: RemoteBrowserSnapshot = HostedStore.snapshot(),
      mode: RemoteViewportMode = .keep
    ) async throws {
      hosted = HostedStore(mode: mode)
      view = RemoteBrowserView(store: hosted.store)
      screen = try InProcessWindow(view: view, width: 1000, height: 1000)
      touch = RemoteTouchController(view: view, pinch: pinch, pan: pan, longPress: longPress)
      view.touchInput = touch
      editMenu = RecordingEditMenu(delegate: touch)
      view.addInteraction(editMenu)
      touch.editMenu = editMenu
      await hosted.hostSends(snapshot)
    }

    func finish() {
      touch.stopMomentum()
      screen.close()
      hosted.finish()
    }

    var mice: [MouseInput] { hosted.connector.driver.mice }

    /// The video's rubber-band displacement.
    var stretch: (x: Double, y: Double) { (Double(view.rubberBand.x), Double(view.rubberBand.y)) }

    /// How visible the mobile page's scroll indicator is: 0 hidden, 1 shown.
    var indicatorOpacity: Float? {
      view.layer.sublayers?.first { $0.cornerRadius == RemoteScrollIndicator.width / 2 }?.opacity
    }

    /// A page that scrolls vertically, `offset` CSS px down a page four viewports tall.
    static func scrolling(at offset: Double = 100) -> RemoteBrowserSnapshot {
      var snapshot = HostedStore.snapshot()
      snapshot.scroll = RemoteScrollMetrics(
        x: 0, y: offset, contentWidth: 1000, contentHeight: 2000, viewportWidth: 1000,
        viewportHeight: 500)
      return snapshot
    }

    func tap(_ across: CGFloat, _ down: CGFloat) {
      touch.handleTap(ScriptedTap(at: CGPoint(x: across, y: down)))
    }

    func doubleTap(_ across: CGFloat, _ down: CGFloat) {
      touch.handleDoubleTap(ScriptedTap(at: CGPoint(x: across, y: down)))
    }

    /// One step of a pan: the finger is at `point`, having moved `moved` since the last step.
    func drag(
      _ phase: UIGestureRecognizer.State, to point: CGPoint, moved: CGPoint = .zero,
      speed: CGPoint = .zero, fingers: Int = 1
    ) {
      pan.phase = phase
      pan.point = point
      pan.moved = moved
      pan.speed = speed
      pan.fingers = fingers
      touch.handlePan(pan)
    }

    func squeeze(_ phase: UIGestureRecognizer.State, scale: CGFloat = 1, at point: CGPoint) {
      pinch.phase = phase
      pinch.point = point
      pinch.scale = scale
      touch.handlePinch(pinch)
    }

    func press(_ phase: UIGestureRecognizer.State, at point: CGPoint) {
      longPress.phase = phase
      longPress.point = point
      touch.handleLongPress(longPress)
    }

    /// Waits until `condition` holds, checking each display frame or so.
    func wait(
      upTo limit: Duration = .seconds(4), until condition: () -> Bool
    ) async -> Bool {
      let deadline = ContinuousClock.now + limit
      while ContinuousClock.now < deadline {
        if condition() { return true }
        await screen.settle(.milliseconds(20))
      }
      return condition()
    }

    /// Waits until no pointer event has arrived for a while: momentum has run out.
    func waitForStillness() async {
      var seen = -1
      while seen != mice.count {
        seen = mice.count
        await screen.settle(.milliseconds(250))
      }
    }
  }
#endif
