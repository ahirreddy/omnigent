#if os(iOS)
  import Foundation
  import OmnigentCoreFFI
  import OmnigentViewTesting
  import Testing
  import UIKit

  @testable import OmnigentRemoteBrowser

  @MainActor
  @Suite("Remote page touch: taps and pinch", .serialized)
  struct RemoteTouchTapTests {
    @Test("a tap clicks the page under the finger and takes the keyboard focus")
    func tapClicks() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      page.tap(100, 350)
      let mice = page.mice
      try #require(mice.count == 3)
      #expect(mice.map(\.kind) == [.move, .down, .up])
      #expect(mice.map(\.x) == [100, 100, 100])
      #expect(mice.map(\.y) == [100, 100, 100])
      #expect(mice.map(\.button) == [nil, .left, .left])
      #expect(mice.map(\.clicks) == [0, 1, 1])
      #expect(mice.map(\.modifiers) == [0, RemoteModifiers.leftButton.rawValue, 0])
      #expect(page.view.isFirstResponder)
      #expect(page.view.lastTapAt != nil)
      #expect(page.editMenu.dismissals == 1)
    }

    @Test("a tap on the letterbox clicks nothing, and still counts as a tap for the keyboard")
    func tapOutsideThePage() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      page.tap(100, 100)
      #expect(page.mice.isEmpty)
      #expect(page.view.lastTapAt != nil)
      #expect(page.view.isFirstResponder)
    }

    @Test("a tap leaves the software keyboard up while a remote field is being edited")
    func tapKeepsTheKeyboard() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      #expect(page.view.keyboardProxy.becomeFirstResponder())
      page.tap(100, 350)
      #expect(page.view.keyboardProxy.isFirstResponder)
      #expect(!page.view.isFirstResponder)
      #expect(page.mice.map(\.kind) == [.move, .down, .up])
    }

    @Test("while the agent drives, a tap reaches nothing")
    func tapWithoutControl() async throws {
      let page = try await TouchPage(HostedStore.snapshot(owner: .agent, holder: .nobody))
      defer { page.finish() }
      page.tap(100, 350)
      #expect(page.mice.isEmpty)
    }

    @Test("a two-finger tap is a right click")
    func twoFingerTap() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      let fingers = ScriptedTap()
      fingers.point = CGPoint(x: 600, y: 700)
      page.touch.handleTwoFingerTap(fingers)
      let mice = page.mice
      try #require(mice.count == 3)
      #expect(mice.map(\.kind) == [.move, .down, .up])
      #expect(mice.map(\.button) == [nil, .right, .right])
      #expect(mice[1].x == 600)
      #expect(mice[1].y == 450)
      #expect(mice[1].modifiers == RemoteModifiers.rightButton.rawValue)
      fingers.point = CGPoint(x: 600, y: 900)
      page.touch.handleTwoFingerTap(fingers)
      #expect(page.mice.count == 3)
    }

    @Test("a double tap zooms in at the finger, the next one zooms back out")
    func doubleTapZooms() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      let before = try #require(page.touch.css(CGPoint(x: 400, y: 500)))
      page.doubleTap(400, 500)
      #expect(page.view.zoom.isZoomed)
      #expect(page.view.zoom.scale == RemoteZoomState.doubleTapScale)
      #expect(page.hosted.store.zoomPercent == 250)
      #expect(page.view.accessibilityValue?.hasSuffix("zoomed 250%") == true)
      // The page point under the finger stays under it, so a tap there clicks the same place.
      let after = try #require(page.touch.css(CGPoint(x: 400, y: 500)))
      #expect(abs(after.x - before.x) < 0.001)
      #expect(abs(after.y - before.y) < 0.001)
      #expect(page.mice.isEmpty)
      page.doubleTap(400, 500)
      #expect(!page.view.zoom.isZoomed)
      #expect(page.hosted.store.zoomPercent == nil)
    }

    @Test("a pinch zooms about its centre and each change starts from the last")
    func pinchZooms() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      let centre = CGPoint(x: 500, y: 500)
      page.squeeze(.began, at: centre)
      #expect(!page.view.zoom.isZoomed)
      page.squeeze(.changed, scale: 2, at: centre)
      #expect(page.view.zoom.scale == 2)
      #expect(page.pinch.scale == 1)
      page.squeeze(.changed, scale: 1.5, at: centre)
      #expect(page.view.zoom.scale == 3)
      page.squeeze(.ended, at: centre)
      #expect(page.view.zoom.scale == 3)
      #expect(page.hosted.store.zoomPercent == 300)
      // Still possible: a recognizer that has not begun changes nothing.
      page.squeeze(.possible, scale: 4, at: centre)
      #expect(page.view.zoom.scale == 3)
    }

    @Test("a pinch past either limit stretches, then settles inside the limits when let go")
    func pinchRubberBands() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      let centre = CGPoint(x: 500, y: 500)
      page.squeeze(.changed, scale: 0.5, at: centre)
      #expect(page.view.zoom.scale < 1)
      #expect(page.view.zoom.scale > 0.5)
      page.squeeze(.cancelled, at: centre)
      #expect(page.view.zoom == RemoteZoomState())

      page.squeeze(.changed, scale: 10, at: centre)
      #expect(page.view.zoom.scale > RemoteZoomState.maxScale)
      page.squeeze(.failed, at: centre)
      #expect(page.view.zoom.scale == RemoteZoomState.maxScale)
    }
  }

  @MainActor
  @Suite("Remote page touch: long press, the edit menu and hover", .serialized)
  struct RemoteTouchSelectionTests {
    @Test("a long press double-clicks to select a word, drags to extend, then offers the menu")
    func longPressSelects() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      let held = RemoteModifiers.leftButton.rawValue
      page.press(.began, at: CGPoint(x: 200, y: 300))
      #expect(page.mice.map(\.kind) == [.move, .down, .up, .down])
      #expect(page.mice.map(\.clicks) == [0, 1, 1, 2])
      #expect(page.mice.map(\.modifiers) == [0, held, 0, held])
      #expect(page.mice.allSatisfy { $0.x == 200 && $0.y == 50 })
      #expect(page.view.isFirstResponder)
      #expect(page.editMenu.dismissals == 1)

      page.press(.changed, at: CGPoint(x: 260, y: 300))
      #expect(page.mice.last?.kind == .move)
      #expect(page.mice.last?.x == 260)
      #expect(page.mice.last?.modifiers == held)

      page.press(.ended, at: CGPoint(x: 260, y: 320))
      #expect(page.mice.last?.kind == .up)
      #expect(page.mice.last?.clicks == 2)
      #expect(page.mice.count == 6)
      #expect(page.touch.menuAnchor == CGPoint(x: 260, y: 320))
      // The menu waits for the host's selection report; with none it opens where the finger lifted.
      #expect(page.editMenu.presentedAt.isEmpty)
      #expect(await page.wait { !page.editMenu.presentedAt.isEmpty })
      #expect(page.editMenu.presentedAt == [CGPoint(x: 260, y: 320)])
    }

    @Test("a tap or a new press before the menu appears calls it off")
    func menuCalledOff() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      page.press(.began, at: CGPoint(x: 200, y: 300))
      page.press(.ended, at: CGPoint(x: 200, y: 300))
      page.tap(600, 600)
      await page.screen.settle(.milliseconds(400))
      #expect(page.editMenu.presentedAt.isEmpty)

      // Two presses in quick succession show one menu, for the second.
      page.press(.ended, at: CGPoint(x: 200, y: 300))
      page.press(.began, at: CGPoint(x: 700, y: 400))
      page.press(.ended, at: CGPoint(x: 700, y: 400))
      await page.screen.settle(.milliseconds(400))
      #expect(page.editMenu.presentedAt == [CGPoint(x: 700, y: 400)])
    }

    @Test(
      "a long press outside the page is clamped to its edge, and does nothing unless in control")
    func longPressEdges() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      page.press(.began, at: CGPoint(x: 200, y: 100))
      #expect(page.mice.allSatisfy { $0.y == 0 })
      #expect(page.mice.count == 4)
      // A recognizer that has not begun sends nothing.
      page.press(.possible, at: CGPoint(x: 200, y: 300))
      #expect(page.mice.count == 4)

      let watching = try await TouchPage(HostedStore.snapshot(owner: .agent, holder: .nobody))
      defer { watching.finish() }
      watching.press(.began, at: CGPoint(x: 200, y: 300))
      #expect(watching.mice.isEmpty)
      #expect(watching.editMenu.dismissals == 0)
    }

    @Test("the edit menu opens above the page's selection, and takes the focus it needs")
    func menuAtTheSelection() async throws {
      var snapshot = HostedStore.snapshot()
      snapshot.selection = RemoteSelection(
        editable: true, collapsed: false, length: 4,
        rect: RemoteRect(x: 100, y: 100, width: 50, height: 20))
      let page = try await TouchPage(snapshot)
      defer { page.finish() }
      #expect(!page.view.isFirstResponder)
      page.touch.menuAnchor = CGPoint(x: 9, y: 9)
      page.touch.presentEditMenu()
      #expect(page.editMenu.presentedAt == [CGPoint(x: 125, y: 350)])
      #expect(page.view.isFirstResponder)
      let target = page.touch.editMenuInteraction(
        page.editMenu,
        targetRectFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: 9, y: 9)))
      #expect(target == CGRect(x: 100, y: 350, width: 50, height: 20))
    }

    @Test("with no selection and no long press there is nowhere to open the menu")
    func menuWithoutAnAnchor() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      page.touch.presentEditMenu()
      #expect(page.editMenu.presentedAt.isEmpty)
      #expect(!page.view.isFirstResponder)
      let target = page.touch.editMenuInteraction(
        page.editMenu,
        targetRectFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: 40, y: 60)))
      #expect(target == CGRect(x: 39, y: 59, width: 2, height: 2))
    }

    @Test("a pointer moves the page's mouse and leaves it, except in the middle of a touch")
    func hover() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      let pointer = ScriptedHover()
      pointer.point = CGPoint(x: 300, y: 400)
      pointer.phase = .changed
      page.touch.handleHover(pointer)
      #expect(page.mice.map(\.kind) == [.move])
      #expect(page.mice.last?.y == 150)
      #expect(page.mice.last?.button == nil)
      pointer.point = CGPoint(x: 300, y: 990)
      pointer.phase = .ended
      page.touch.handleHover(pointer)
      #expect(page.mice.map(\.kind) == [.move, .leave])
      #expect(page.mice.last?.y == 499)

      page.pan.phase = .changed
      pointer.phase = .changed
      page.touch.handleHover(pointer)
      #expect(page.mice.count == 2)
      page.pan.phase = .possible
      page.longPress.phase = .began
      page.touch.handleHover(pointer)
      #expect(page.mice.count == 2)
    }

    @Test("pinch and pan run together, hover runs with anything, and nothing else does")
    func simultaneousGestures() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      let touch = page.touch
      #expect(touch.gestureRecognizer(touch.pinch, shouldRecognizeSimultaneouslyWith: touch.pan))
      #expect(touch.gestureRecognizer(touch.pan, shouldRecognizeSimultaneouslyWith: touch.pinch))
      #expect(touch.gestureRecognizer(touch.hover, shouldRecognizeSimultaneouslyWith: touch.tap))
      #expect(touch.gestureRecognizer(touch.pan, shouldRecognizeSimultaneouslyWith: touch.hover))
      #expect(!touch.gestureRecognizer(touch.tap, shouldRecognizeSimultaneouslyWith: touch.pan))
      #expect(
        !touch.gestureRecognizer(touch.longPress, shouldRecognizeSimultaneouslyWith: touch.pan))
    }

    @Test("a tap waits for a double tap only where double tap zooms; a pan waits for a long press")
    func gestureOrder() async throws {
      let desktop = try await TouchPage()
      defer { desktop.finish() }
      var touch = desktop.touch
      #expect(touch.gestureRecognizer(touch.tap, shouldRequireFailureOf: touch.doubleTap))
      #expect(touch.gestureRecognizer(touch.pan, shouldRequireFailureOf: touch.longPress))
      #expect(!touch.gestureRecognizer(touch.pan, shouldRequireFailureOf: touch.tap))
      #expect(!touch.gestureRecognizer(touch.twoFingerTap, shouldRequireFailureOf: touch.longPress))
      #expect(touch.gestureRecognizerShouldBegin(touch.doubleTap))
      #expect(touch.gestureRecognizerShouldBegin(touch.tap))

      let mobile = try await TouchPage(mode: .mobile(site: false))
      defer { mobile.finish() }
      touch = mobile.touch
      #expect(!touch.gestureRecognizer(touch.tap, shouldRequireFailureOf: touch.doubleTap))
      #expect(!touch.gestureRecognizerShouldBegin(touch.doubleTap))
      #expect(touch.gestureRecognizerShouldBegin(touch.pan))
    }

    @Test("a controller that outlives its view answers as the desktop modes do and sends nothing")
    func viewGone() {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let touch = autoreleasepool {
        RemoteTouchController(view: RemoteBrowserView(store: hosted.store))
      }
      #expect(touch.view == nil)
      #expect(touch.gestureRecognizer(touch.tap, shouldRequireFailureOf: touch.doubleTap))
      #expect(touch.gestureRecognizerShouldBegin(touch.doubleTap))
      #expect(touch.fit == .zero)
      #expect(touch.bounds == .zero)
      #expect(touch.css(CGPoint(x: 1, y: 1)) == nil)
      touch.handleTap(ScriptedTap())
      touch.handleDoubleTap(ScriptedTap())
      touch.handleTwoFingerTap(ScriptedTap())
      touch.handlePinch(ScriptedPinch())
      touch.handlePan(ScriptedPan())
      touch.handleLongPress(ScriptedLongPress())
      touch.handleHover(ScriptedHover())
      touch.presentEditMenu()
      #expect(hosted.connector.driver.mice.isEmpty)
    }
  }
#endif
