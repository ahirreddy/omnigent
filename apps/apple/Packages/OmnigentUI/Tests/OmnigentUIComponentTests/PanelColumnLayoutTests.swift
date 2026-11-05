import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("iPad right panel column")
struct PanelColumnLayoutTests {
  @Test("the panel keeps the inspector's ideal width and narrows in a tight split")
  func panelWidth() {
    #expect(PanelColumnLayout.panelWidth(in: 1_000) == 360)
    #expect(PanelColumnLayout.panelWidth(in: 700) == 315)
    #expect(PanelColumnLayout.panelWidth(in: 400) == 260)
  }
}
