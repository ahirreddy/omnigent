import OmnigentServices
import Testing

/// When a reading of the network route means connections should try the server again at once.
@Suite("Network path")
struct NetworkPathTests {
  private let wifi = NetworkPath(isSatisfied: true, interfaces: ["en0"])
  private let none = NetworkPath(isSatisfied: false, interfaces: [])

  @Test("The network coming back, or a different one, is a return; the first reading is not")
  func returns() {
    #expect(!wifi.isReturn(after: nil), "the reading at start")
    #expect(wifi.isReturn(after: none), "back online")
    #expect(
      NetworkPath(isSatisfied: true, interfaces: ["en0", "utun3"]).isReturn(after: wifi),
      "a VPN came up")
    #expect(NetworkPath(isSatisfied: true, interfaces: ["en1"]).isReturn(after: wifi))
  }

  @Test("The same network again, or no network, is not a return")
  func notReturns() {
    #expect(!wifi.isReturn(after: wifi))
    #expect(!none.isReturn(after: wifi))
    #expect(!none.isReturn(after: none))
  }
}
