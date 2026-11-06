import CoreGraphics
import Testing

@testable import OmnigentUIComponents

/// A collapsed sidebar peeks over the content from the window's leading edge.
@Suite("Sidebar peek")
struct SidebarPeekTests {
  private let panel: CGFloat = 248

  @Test("resting on the edge reveals the panel once the delay passes")
  func revealsAfterDelay() throws {
    var peek = SidebarPeek()
    peek.pointerMoved(to: 2, panelWidth: panel, isBlocked: false)
    #expect(!peek.isShown)
    let timer = try #require(peek.pendingTimer)
    #expect(timer.delay == SidebarPeek.revealDelay)
    peek.timerFired(timer.token)
    #expect(peek.phase == .shown)
    #expect(peek.pendingTimer == nil)
  }

  @Test("passing over the edge before the delay reveals nothing")
  func passingOverEdge() throws {
    var peek = SidebarPeek()
    peek.pointerMoved(to: 0, panelWidth: panel, isBlocked: false)
    let timer = try #require(peek.pendingTimer)
    peek.pointerMoved(to: 40, panelWidth: panel, isBlocked: false)
    peek.timerFired(timer.token)
    #expect(peek.phase == .hidden)
  }

  @Test("away from the edge, a drag or a sheet, the edge reveals nothing")
  func blockedOrAway() {
    var peek = SidebarPeek()
    peek.pointerMoved(to: SidebarPeek.edgeWidth + 1, panelWidth: panel, isBlocked: false)
    peek.pointerMoved(to: nil, panelWidth: panel, isBlocked: false)
    peek.pointerMoved(to: 1, panelWidth: panel, isBlocked: true)
    #expect(peek.phase == .hidden)

    peek.pointerMoved(to: 1, panelWidth: panel, isBlocked: false)
    peek.pointerMoved(to: 1, panelWidth: panel, isBlocked: true)
    #expect(peek.phase == .hidden)
  }

  @Test("leaving the panel hides it after a delay; coming back keeps it")
  func hidesAfterLeaving() throws {
    var peek = shown()
    peek.pointerMoved(to: 120, panelWidth: panel, isBlocked: false)
    #expect(peek.phase == .shown)

    peek.pointerMoved(to: panel + 30, panelWidth: panel, isBlocked: false)
    let first = try #require(peek.pendingTimer)
    #expect(first.delay == SidebarPeek.hideDelay)
    #expect(peek.isShown)
    peek.pointerMoved(to: 100, panelWidth: panel, isBlocked: false)
    peek.timerFired(first.token)
    #expect(peek.phase == .shown)

    peek.pointerMoved(to: nil, panelWidth: panel, isBlocked: false)
    let second = try #require(peek.pendingTimer)
    #expect(second.token != first.token)
    peek.timerFired(first.token)
    #expect(peek.isShown)
    peek.timerFired(second.token)
    #expect(peek.phase == .hidden)
  }

  @Test("a shown panel stays while its sheet or a drag is in progress")
  func staysWhileBlocked() {
    var peek = shown()
    peek.pointerMoved(to: 600, panelWidth: panel, isBlocked: true)
    #expect(peek.phase == .shown)
    peek.pointerMoved(to: 600, panelWidth: panel, isBlocked: false)
    peek.pointerMoved(to: 600, panelWidth: panel, isBlocked: true)
    #expect(peek.phase == .shown)
  }

  @Test("pinning the sidebar ends the peek and any pending delay")
  func resetEndsPeek() {
    var peek = shown()
    peek.pointerMoved(to: nil, panelWidth: panel, isBlocked: false)
    peek.reset()
    #expect(peek.phase == .hidden)
    #expect(peek.pendingTimer == nil)
    #expect(SidebarPeek(isShown: true).phase == .shown)
  }

  private func shown() -> SidebarPeek {
    var peek = SidebarPeek()
    peek.pointerMoved(to: 0, panelWidth: panel, isBlocked: false)
    if let timer = peek.pendingTimer { peek.timerFired(timer.token) }
    return peek
  }
}
