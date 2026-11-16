import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Tab strip widths")
struct TabStripLayoutTests {
  @Test("Tabs share the room evenly up to the maximum")
  func evenShares() {
    let roomy = TabStrip.widths(available: 1_000, count: 3, includesSelected: true)
    #expect(roomy.selected == TabMetrics.maxWidth)
    #expect(roomy.other == TabMetrics.maxWidth)
    let snug = TabStrip.widths(available: 860, count: 4, includesSelected: true)
    #expect(snug.selected == snug.other)
    #expect(snug.other >= TabMetrics.selectedWidth)
  }

  @Test("Once they shrink, the selected tab keeps its title width")
  func selectedStaysReadable() {
    let crowded = TabStrip.widths(available: 820, count: 7, includesSelected: true)
    #expect(crowded.selected == TabMetrics.selectedWidth)
    #expect(crowded.other >= TabMetrics.minWidth)
    #expect(crowded.other < TabMetrics.selectedWidth)
  }

  @Test("Background tabs never go below the minimum; the strip scrolls instead")
  func minimumThenScroll() {
    let packed = TabStrip.widths(available: 600, count: 12, includesSelected: true)
    #expect(packed.selected == TabMetrics.selectedWidth)
    #expect(packed.other == TabMetrics.minWidth)
    let noSelection = TabStrip.widths(available: 600, count: 12, includesSelected: false)
    #expect(noSelection.selected == TabMetrics.minWidth)
    #expect(noSelection.other == TabMetrics.minWidth)
  }
}
