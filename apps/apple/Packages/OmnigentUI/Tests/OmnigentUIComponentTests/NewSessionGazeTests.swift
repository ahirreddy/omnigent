import CoreGraphics
import Testing

@testable import OmnigentUIComponents

/// The mascot on the new session page watches the pointer.
@Suite("New session: the mascot's gaze")
struct NewSessionGazeTests {
  private let size = CGSize(width: 200, height: 100)

  @Test("The mascot looks straight ahead from the middle, and to each edge from that edge")
  @MainActor
  func gaze() {
    #expect(NewSessionPage.gaze(at: CGPoint(x: 100, y: 50), in: size) == .zero)
    #expect(
      NewSessionPage.gaze(at: .zero, in: size) == CGSize(width: -1, height: -1))
    #expect(
      NewSessionPage.gaze(at: CGPoint(x: 200, y: 100), in: size) == CGSize(width: 1, height: 1))
  }

  @Test("A page with no size yet doesn't divide by zero")
  @MainActor
  func emptyPage() {
    #expect(NewSessionPage.gaze(at: .zero, in: .zero) == CGSize(width: -1, height: -1))
  }
}
