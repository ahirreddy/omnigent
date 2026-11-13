#if os(iOS)
  import Foundation
  import OmnigentCoreFFI
  import OmnigentViewTesting
  import Testing
  import UIKit

  @testable import OmnigentRemoteBrowser

  @MainActor
  @Suite("Remote page touch: scrolling", .serialized)
  struct RemoteTouchScrollTests {
    @Test("a finger moving down scrolls the page up, by the distance it moved")
    func dragScrolls() async throws {
      let page = try await TouchPage(TouchPage.scrolling())
      defer { page.finish() }
      // The recognizer begins after the finger has already moved 10 points.
      page.drag(.began, to: CGPoint(x: 500, y: 410), moved: CGPoint(x: 0, y: 10))
      page.drag(.changed, to: CGPoint(x: 500, y: 430), moved: CGPoint(x: 0, y: 20))
      page.drag(.changed, to: CGPoint(x: 500, y: 400), moved: CGPoint(x: 0, y: -30))
      page.drag(.ended, to: CGPoint(x: 500, y: 400))
      let wheels = page.mice
      #expect(wheels.map(\.kind) == [.wheel, .wheel, .wheel])
      #expect(wheels.map(\.dy) == [-10, -20, 30])
      #expect(wheels.map(\.dx) == [0, 0, 0])
      #expect(wheels.map(\.y) == [160, 180, 150])
      #expect(wheels.allSatisfy { $0.button == nil && $0.clicks == 0 })
      #expect(page.pan.moved == .zero)
      #expect(page.view.rubberBand == .zero)
    }

    @Test("past the page's top the video stretches instead, and gives back before scrolling")
    func rubberBand() async throws {
      let page = try await TouchPage(TouchPage.scrolling(at: 0))
      defer { page.finish() }
      page.drag(.began, to: CGPoint(x: 500, y: 400))
      page.drag(.changed, to: CGPoint(x: 500, y: 430), moved: CGPoint(x: 0, y: 30))
      #expect(page.mice.isEmpty)
      #expect(page.stretch.y == RemoteScrollPhysics.rubberBand(30, dimension: 1000))
      #expect(page.view.rubberBand.y > 0)
      #expect(page.view.rubberBand.y < 30)

      // Back up 10: the stretch gives 10 back and the page still isn't scrolled.
      page.drag(.changed, to: CGPoint(x: 500, y: 420), moved: CGPoint(x: 0, y: -10))
      #expect(page.mice.isEmpty)
      #expect(page.stretch.y == RemoteScrollPhysics.rubberBand(20, dimension: 1000))

      // Up 30 more: 20 undo the stretch and the last 10 scroll the page down.
      page.drag(.changed, to: CGPoint(x: 500, y: 390), moved: CGPoint(x: 0, y: -30))
      #expect(page.mice.map(\.dy) == [10])
      #expect(page.view.rubberBand == .zero)
    }

    @Test("sideways, a page no wider than its viewport only stretches, in either direction")
    func horizontalRubberBand() async throws {
      let page = try await TouchPage(TouchPage.scrolling())
      defer { page.finish() }
      page.drag(.began, to: CGPoint(x: 500, y: 400))
      page.drag(.changed, to: CGPoint(x: 540, y: 400), moved: CGPoint(x: 40, y: 0))
      #expect(page.mice.isEmpty)
      #expect(page.stretch.x == RemoteScrollPhysics.rubberBand(40, dimension: 1000))
      page.drag(.changed, to: CGPoint(x: 440, y: 400), moved: CGPoint(x: -100, y: 0))
      #expect(page.mice.isEmpty)
      #expect(page.stretch.x == RemoteScrollPhysics.rubberBand(-60, dimension: 1000))
      #expect(page.view.rubberBand.x < 0)
    }

    @Test("a stretched page springs back once the finger lifts")
    func springBack() async throws {
      let page = try await TouchPage(TouchPage.scrolling(at: 0))
      defer { page.finish() }
      page.drag(.began, to: CGPoint(x: 500, y: 400))
      page.drag(.changed, to: CGPoint(x: 500, y: 480), moved: CGPoint(x: 0, y: 80))
      let stretched = page.view.rubberBand.y
      #expect(stretched > 0)
      page.drag(.ended, to: CGPoint(x: 500, y: 480))
      #expect(await page.wait { page.view.rubberBand.y < stretched })
      #expect(await page.wait { page.view.rubberBand == .zero })
      #expect(page.mice.isEmpty)
    }

    @Test("a flick keeps scrolling the way the finger went, slows, and stops")
    func momentum() async throws {
      let page = try await TouchPage(TouchPage.scrolling(at: 600))
      defer { page.finish() }
      page.drag(.began, to: CGPoint(x: 500, y: 400))
      page.drag(.changed, to: CGPoint(x: 500, y: 380), moved: CGPoint(x: 0, y: -20))
      #expect(page.mice.map(\.dy) == [20])
      page.drag(.ended, to: CGPoint(x: 500, y: 380), speed: CGPoint(x: 0, y: -120))
      await page.waitForStillness()
      let coasted = page.mice.dropFirst()
      #expect(coasted.count > 3)
      #expect(coasted.allSatisfy { $0.kind == .wheel && $0.dy > 0 && $0.dx == 0 })
      // 120 points a second decays to about 60 points of travel; a slow frame only loses some.
      let travelled = coasted.map(\.dy).reduce(0, +)
      #expect(travelled > 15)
      #expect(travelled < 61)
    }

    @Test("a slow lift, a cancelled pan and a pinch all leave the page where it is")
    func noMomentum() async throws {
      let page = try await TouchPage(TouchPage.scrolling(at: 600))
      defer { page.finish() }
      page.drag(.began, to: CGPoint(x: 500, y: 400))
      page.drag(.ended, to: CGPoint(x: 500, y: 400), speed: CGPoint(x: 0, y: -40))
      page.drag(.began, to: CGPoint(x: 500, y: 400))
      page.drag(.cancelled, to: CGPoint(x: 500, y: 400), speed: CGPoint(x: 0, y: -900))
      await page.screen.settle(.milliseconds(200))
      #expect(page.mice.isEmpty)

      // A flick, interrupted by two fingers coming down to pinch.
      page.drag(.began, to: CGPoint(x: 500, y: 400))
      page.drag(.ended, to: CGPoint(x: 500, y: 400), speed: CGPoint(x: 0, y: -900))
      #expect(await page.wait { page.mice.count >= 2 })
      page.squeeze(.began, at: CGPoint(x: 500, y: 500))
      let sent = page.mice.count
      await page.screen.settle(.milliseconds(200))
      #expect(page.mice.count == sent)
    }

    @Test("momentum that reaches the page's edge stretches a little and springs back")
    func momentumIntoTheEdge() async throws {
      let page = try await TouchPage(TouchPage.scrolling(at: 0))
      defer { page.finish() }
      page.drag(.began, to: CGPoint(x: 500, y: 400))
      page.drag(.ended, to: CGPoint(x: 500, y: 400), speed: CGPoint(x: 0, y: 400))
      var furthest = 0.0
      let bounced = await page.wait {
        furthest = max(furthest, page.view.rubberBand.y)
        return furthest > 0 && page.view.rubberBand == .zero
      }
      #expect(bounced)
      #expect(furthest > 0)
      #expect(page.mice.isEmpty)
    }

    @Test("while the agent drives, a drag scrolls nothing and stretches nothing")
    func dragWithoutControl() async throws {
      var snapshot = TouchPage.scrolling()
      snapshot.control = RemoteBrowserControl(
        owner: .agent, holder: .nobody, userId: nil, handoff: nil)
      let page = try await TouchPage(snapshot)
      defer { page.finish() }
      page.drag(.began, to: CGPoint(x: 990, y: 400))
      page.drag(.changed, to: CGPoint(x: 990, y: 300), moved: CGPoint(x: 0, y: -100))
      page.drag(.ended, to: CGPoint(x: 990, y: 300))
      await page.screen.settle(.milliseconds(120))
      #expect(page.mice.isEmpty)
      #expect(page.view.rubberBand == .zero)
    }
  }

  @MainActor
  @Suite("Remote page touch: the zoomed page, scroll bars and the indicator", .serialized)
  struct RemoteTouchPanModeTests {
    @Test("one finger moves the zoomed video first and scrolls the page with what is left")
    func zoomedPan() async throws {
      let page = try await TouchPage(TouchPage.scrolling())
      defer { page.finish() }
      page.doubleTap(500, 500)
      let start = page.view.zoom.offset
      page.drag(.began, to: CGPoint(x: 500, y: 500))
      page.drag(.changed, to: CGPoint(x: 500, y: 460), moved: CGPoint(x: 0, y: -40))
      #expect(page.view.zoom.offset.y == start.y - 40)
      #expect(page.mice.isEmpty)

      // Far past the zoomed video's bottom: the video stops at its edge and the page scrolls.
      page.drag(.changed, to: CGPoint(x: 500, y: 460), moved: CGPoint(x: 0, y: -2000))
      let moved = start.y - 40 - page.view.zoom.offset.y
      #expect(moved > 0)
      #expect(moved < 2000)
      let wheel = try #require(page.mice.last)
      #expect(page.mice.count == 1)
      #expect(abs(wheel.dy - (2000 - moved) / RemoteZoomState.doubleTapScale) < 0.001)
    }

    @Test("two fingers scroll the page even when zoomed")
    func zoomedTwoFingerScroll() async throws {
      let page = try await TouchPage(TouchPage.scrolling())
      defer { page.finish() }
      page.doubleTap(500, 500)
      let start = page.view.zoom.offset
      page.drag(.began, to: CGPoint(x: 500, y: 500), fingers: 2)
      page.drag(.changed, to: CGPoint(x: 500, y: 450), moved: CGPoint(x: 0, y: -50), fingers: 2)
      #expect(page.view.zoom.offset == start)
      #expect(page.mice.map(\.dy) == [50 / RemoteZoomState.doubleTapScale])
    }

    @Test("fingers moving during a pinch move the zoomed video, never the page")
    func panDuringPinch() async throws {
      let page = try await TouchPage(TouchPage.scrolling())
      defer { page.finish() }
      page.doubleTap(500, 500)
      let start = page.view.zoom.offset
      page.pinch.phase = .changed
      page.drag(.began, to: CGPoint(x: 500, y: 500), fingers: 2)
      page.drag(.changed, to: CGPoint(x: 470, y: 500), moved: CGPoint(x: -30, y: 0), fingers: 2)
      #expect(page.view.zoom.offset.x == start.x - 30)
      #expect(page.mice.isEmpty)
    }

    @Test("a drag that starts on a desktop page's scroll bar grabs it with the mouse")
    func scrollBarDrag() async throws {
      let page = try await TouchPage(TouchPage.scrolling())
      defer { page.finish() }
      let held = RemoteModifiers.leftButton.rawValue
      page.drag(.began, to: CGPoint(x: 990, y: 400))
      // One pixel of wheel shows an overlay scroll bar; the button goes down shortly after.
      #expect(page.mice.map(\.kind) == [.wheel])
      #expect(page.mice.first?.dy == 1)
      page.drag(.changed, to: CGPoint(x: 990, y: 420), moved: CGPoint(x: 0, y: 20))
      #expect(page.mice.count == 1)
      #expect(await page.wait { page.mice.count >= 4 })
      #expect(page.mice.map(\.kind) == [.wheel, .move, .down, .move])
      #expect(page.mice.map(\.y) == [150, 150, 150, 170])
      #expect(page.mice[2].button == .left)
      #expect(page.mice[2].modifiers == held)
      #expect(page.mice[3].modifiers == held)

      page.drag(.changed, to: CGPoint(x: 990, y: 500), moved: CGPoint(x: 0, y: 80))
      #expect(page.mice.last?.kind == .move)
      #expect(page.mice.last?.y == 250)
      #expect(page.mice.last?.modifiers == held)
      // Lifting below the page releases at its last row.
      page.drag(.ended, to: CGPoint(x: 990, y: 900), speed: CGPoint(x: 0, y: 900))
      #expect(page.mice.last?.kind == .up)
      #expect(page.mice.last?.y == 499)
      #expect(page.mice.last?.button == .left)
      await page.screen.settle(.milliseconds(150))
      #expect(page.mice.count == 6)
    }

    @Test("a touch on the scroll bar that lifts at once never presses the mouse")
    func scrollBarTouchTooShort() async throws {
      let page = try await TouchPage(TouchPage.scrolling())
      defer { page.finish() }
      page.drag(.began, to: CGPoint(x: 990, y: 400))
      page.drag(.ended, to: CGPoint(x: 990, y: 400))
      await page.screen.settle(.milliseconds(150))
      #expect(page.mice.map(\.kind) == [.wheel])
    }

    @Test("a second touch on the scroll bar presses where it began, not where the first did")
    func scrollBarTouchedTwice() async throws {
      let page = try await TouchPage(TouchPage.scrolling())
      defer { page.finish() }
      page.drag(.began, to: CGPoint(x: 990, y: 400))
      page.drag(.ended, to: CGPoint(x: 990, y: 400))
      page.drag(.began, to: CGPoint(x: 990, y: 600))
      #expect(await page.wait { page.mice.count >= 5 })
      await page.screen.settle(.milliseconds(150))
      #expect(page.mice.map(\.kind) == [.wheel, .wheel, .move, .down, .move])
      #expect(page.mice.map(\.y) == [150, 350, 350, 350, 350])
    }

    @Test("a page that doesn't scroll has no scroll bar to grab")
    func noScrollBar() async throws {
      var snapshot = HostedStore.snapshot()
      snapshot.scroll = RemoteScrollMetrics(
        x: 0, y: 0, contentWidth: 1000, contentHeight: 500, viewportWidth: 1000,
        viewportHeight: 500)
      let page = try await TouchPage(snapshot)
      defer { page.finish() }
      page.drag(.began, to: CGPoint(x: 990, y: 400))
      page.drag(.changed, to: CGPoint(x: 990, y: 380), moved: CGPoint(x: 0, y: -20))
      #expect(page.mice.isEmpty)
      #expect(page.view.rubberBand.y < 0)
    }

    @Test("dragging a mobile page's scroll indicator scrubs to where the thumb is put")
    func scrub() async throws {
      let page = try await TouchPage(TouchPage.scrolling(at: 0), mode: .mobile(site: false))
      defer { page.finish() }
      let metrics = try #require(page.hosted.store.snapshot.scroll)
      let indicator = try #require(page.view.scrollIndicator)
      let grab = CGPoint(x: indicator.thumb.midX, y: indicator.thumb.midY)
      // The indicator showed for the page's first scroll report; it fades before the grab.
      #expect(await page.wait { page.indicatorOpacity == 0 })
      page.drag(.began, to: grab)
      #expect(page.mice.isEmpty)
      #expect(page.indicatorOpacity == 1)

      let middle = indicator.track.midY
      page.drag(.changed, to: CGPoint(x: grab.x, y: middle))
      let target = indicator.scrollOffset(thumbCenterY: middle, metrics: metrics)
      #expect(abs(target - 750) < 0.001)
      #expect(page.mice.map(\.kind) == [.wheel])
      #expect(page.mice.first?.dy == target)
      // The same place again asks for nothing more.
      page.drag(.changed, to: CGPoint(x: grab.x, y: middle))
      #expect(page.mice.count == 1)
      // Further down asks only for the difference.
      page.drag(.changed, to: CGPoint(x: grab.x, y: middle + 60))
      let further = indicator.scrollOffset(thumbCenterY: middle + 60, metrics: metrics)
      #expect(further > target)
      #expect(page.mice.count == 2)
      #expect(abs((page.mice.last?.dy ?? 0) - (further - target)) < 0.001)
      page.drag(.ended, to: CGPoint(x: grab.x, y: middle + 60), speed: CGPoint(x: 0, y: 900))
      await page.screen.settle(.milliseconds(150))
      #expect(page.mice.count == 2)
    }

    @Test("away from the indicator a mobile page scrolls like any other")
    func mobileScroll() async throws {
      let page = try await TouchPage(TouchPage.scrolling(), mode: .mobile(site: false))
      defer { page.finish() }
      #expect(page.hosted.store.viewportMode.isMobile)
      page.drag(.began, to: CGPoint(x: 500, y: 300))
      page.drag(.changed, to: CGPoint(x: 500, y: 280), moved: CGPoint(x: 0, y: -20))
      #expect(page.mice.map(\.dy) == [20])
      let under = try #require(page.touch.css(CGPoint(x: 500, y: 280)))
      #expect(page.mice.first?.y == Double(under.y))
      #expect(page.mice.first?.x == 500)
    }
  }
#endif
