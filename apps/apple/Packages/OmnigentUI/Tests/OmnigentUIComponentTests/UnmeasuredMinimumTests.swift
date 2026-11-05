import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("The detail column answers size questions without measuring its content")
struct UnmeasuredMinimumTests {
  let minimum = CGSize(width: 360, height: 200)

  @Test("the zero and unspecified proposals a hosting controller asks read as the minimum")
  func smallProposals() {
    #expect(UnmeasuredMinimum.size(for: .zero, minimum: minimum) == minimum)
    #expect(UnmeasuredMinimum.size(for: .unspecified, minimum: minimum) == minimum)
  }

  @Test("larger proposals are taken as they are, so the column resizes freely")
  func largerProposals() {
    let size = UnmeasuredMinimum.size(
      for: ProposedViewSize(width: 900, height: 700), minimum: minimum)
    #expect(size == CGSize(width: 900, height: 700))
    let unbounded = UnmeasuredMinimum.size(for: .infinity, minimum: minimum)
    #expect(unbounded.width.isInfinite && unbounded.height.isInfinite)
  }
}
