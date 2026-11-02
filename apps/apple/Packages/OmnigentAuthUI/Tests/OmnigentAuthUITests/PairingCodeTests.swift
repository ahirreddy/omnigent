import CoreGraphics
import Foundation
import Testing

@testable import OmnigentAuthUI

struct PairingCodeTests {
  @Test("Codes round-trip, including mounts and the Databricks selector")
  func roundTrip() throws {
    for url in [
      "https://omnigent.example.com",
      "https://host.example.com:8443/api/2.0/omnigent?o=12345&x=a b",
      "http://127.0.0.1:6767",
    ] {
      let code = PairingCode(serverURL: url)
      #expect(code.text.hasPrefix("omnigent:pair?v=1&server="))
      #expect(!code.text.dropFirst("omnigent:pair?v=1&server=".count).contains("&"))
      #expect(try PairingCode(parsing: code.text) == code)
      #expect(try PairingCode(parsing: "  \(code.text)\n") == code)
    }
  }

  @Test("The QR image encodes the code")
  func renders() {
    let image = PairingQRCodeView.render(PairingCode(serverURL: "https://a.example.com").text)
    #expect((image?.width ?? 0) > 20)
  }

  @Test("Other text is rejected, never read as a deep link")
  func rejects() {
    #expect(throws: PairingCodeError.notAPairingCode) {
      try PairingCode(parsing: "https://omnigent.example.com")
    }
    #expect(throws: PairingCodeError.notAPairingCode) {
      try PairingCode(parsing: "omnigent://pair?v=1&server=https%3A%2F%2Fevil.example.com")
    }
    #expect(throws: PairingCodeError.notAPairingCode) {
      try PairingCode(parsing: "omnigent:connect?v=1&server=https%3A%2F%2Fa.example.com")
    }
    #expect(throws: PairingCodeError.unsupportedVersion) {
      try PairingCode(parsing: "omnigent:pair?v=2&server=https%3A%2F%2Fa.example.com")
    }
    #expect(throws: PairingCodeError.missingServer) {
      try PairingCode(parsing: "omnigent:pair?v=1")
    }
    #expect(throws: PairingCodeError.missingServer) {
      try PairingCode(parsing: "omnigent:pair?v=1&server=%20")
    }
  }

  @Test("Unknown items are ignored so a later version can add a link token")
  func forwardCompatible() throws {
    let code = try PairingCode(
      parsing: "omnigent:pair?v=1&token=abc&server=https%3A%2F%2Fa.example.com")
    #expect(code.serverURL == "https://a.example.com")
  }

  @Test("The core's URL rules decide, and the host is what the user confirms")
  func validation() throws {
    let validator = ServerURLValidator { raw in
      raw.hasPrefix("https://") || raw.hasPrefix("http://127.0.0.1")
        ? .success(raw.lowercased())
        : .failure(ServerURLRejection(message: "This build requires https:// server URLs."))
    }
    let confirmation = try PairingCode(serverURL: "https://Omnigent.Example.com:8443/api")
      .confirmation(validator: validator)
    #expect(confirmation.serverURL == "https://omnigent.example.com:8443/api")
    #expect(confirmation.host == "omnigent.example.com:8443")
    #expect(!confirmation.isLoopback)
    #expect(
      throws: PairingCodeError.invalidServer("This build requires https:// server URLs.")
    ) {
      try PairingCode(serverURL: "http://evil.example.com").confirmation(validator: validator)
    }
    #expect(
      try PairingCode(serverURL: "http://127.0.0.1:6767").confirmation(validator: validator)
        .isLoopback)
  }
}
