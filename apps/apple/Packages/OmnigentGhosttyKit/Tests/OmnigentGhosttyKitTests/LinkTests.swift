import OmnigentGhosttyKit
import Testing

@Suite("GhosttyKit link")
struct LinkTests {
  @Test("the static library links and reports the pinned fork version")
  func reportsVersion() {
    #expect(GhosttyBuildInfo.version.contains("omnigent."))
  }
}
