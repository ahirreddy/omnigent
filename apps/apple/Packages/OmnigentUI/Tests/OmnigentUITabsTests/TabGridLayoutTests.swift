import CoreGraphics
import Testing

@testable import OmnigentUIComponents

struct TabGridLayoutTests {
  @Test(
    "Two columns on iPhone and narrow iPad windows, three in iPad portrait, four in landscape",
    arguments: [
      (CGFloat(402), 2), (507, 2), (834, 3), (1032, 3), (1210, 4), (1376, 4), (2560, 4),
    ])
  func columns(width: CGFloat, expected: Int) {
    #expect(TabGridLayout.columns(width: width) == expected)
  }

  @Test("Cards share the row within the minimum and maximum width")
  func cardWidth() {
    // iPhone keeps its 177-point cards.
    #expect(TabGridLayout.cardWidth(width: 402) == 177)
    // A 13-inch iPad in landscape fills the row with four cards.
    let landscape = TabGridLayout.cardWidth(width: 1376)
    #expect(landscape * 4 + TabGridLayout.spacing * 5 == 1376)
    // A very wide window stops at the maximum and centers the grid.
    #expect(TabGridLayout.cardWidth(width: 2560) == TabGridLayout.maximumCardWidth)
    #expect(TabGridLayout.cardWidth(width: 0) == 0)
  }
}
