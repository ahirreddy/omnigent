import AppKit
import Testing

@testable import OmnigentDesktop

@Suite("Menu bar label")
@MainActor
struct MenuBarLabelTests {
  @Test("reuses one template image per server state")
  func stableIcons() {
    let running = OmnigentMenuBarLabel.icon(isServerRunning: true)
    let stopped = OmnigentMenuBarLabel.icon(isServerRunning: false)
    #expect(running === OmnigentMenuBarLabel.icon(isServerRunning: true))
    #expect(stopped === OmnigentMenuBarLabel.icon(isServerRunning: false))
    #expect(running !== stopped)
    #expect(running.isTemplate && stopped.isTemplate)
    #expect(running.size.width > 0 && stopped.size.width > 0)
  }
}
