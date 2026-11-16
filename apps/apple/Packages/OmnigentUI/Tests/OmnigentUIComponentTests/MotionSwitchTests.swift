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

  @Test("the views' pauses are the app's own unless a test scales them for its duration")
  func pausesScale() {
    #expect(Theme.Timing.pause(.milliseconds(250)) == .milliseconds(250))
    Theme.Timing.scale = 0
    defer { Theme.Timing.scale = 1 }
    #expect(Theme.Timing.pause(.milliseconds(250)) == .zero)
    Theme.Timing.scale = 0.1
    #expect(Theme.Timing.pause(.seconds(1)) == .milliseconds(100))
  }
}
