import SwiftUI
import Testing

@testable import OmnigentUIComponents

@MainActor
@Suite("Animations under test")
struct MotionSwitchTests {
  @Test("a test process's views don't animate, and a test can turn animation back on")
  func animationsAreOff() {
    #expect(!Theme.Motion.isEnabled)
    #expect(Theme.Motion.feedback == nil)
    #expect(Theme.Motion.animation(.snappy) == nil)
    Theme.Motion.isEnabled = true
    defer { Theme.Motion.isEnabled = false }
    #expect(Theme.Motion.disclosure == .easeInOut(duration: 0.2))
  }
}
