import SwiftUI
import Testing

@testable import OmnigentDesktop

@Suite("Window minimum size")
struct WindowMinimumSizeTests {
  let minimum = CGSize(width: 720, height: 600)

  @Test("The zero and unspecified proposals the hosting view asks for read as the minimum")
  func smallProposals() {
    #expect(MinimumSizeLayout.size(for: .zero, minimum: minimum) == minimum)
    #expect(MinimumSizeLayout.size(for: .unspecified, minimum: minimum) == minimum)
    #expect(
      MinimumSizeLayout.size(for: ProposedViewSize(width: 300, height: nil), minimum: minimum)
        == minimum)
  }

  @Test("Larger proposals are taken as they are, so the window resizes freely")
  func largerProposals() {
    let size = MinimumSizeLayout.size(
      for: ProposedViewSize(width: 1280, height: 860), minimum: minimum)
    #expect(size == CGSize(width: 1280, height: 860))
    let unbounded = MinimumSizeLayout.size(for: .infinity, minimum: minimum)
    #expect(unbounded.width.isInfinite && unbounded.height.isInfinite)
  }
}
