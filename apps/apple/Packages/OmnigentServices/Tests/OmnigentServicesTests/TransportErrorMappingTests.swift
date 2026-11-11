import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentServices

struct TransportErrorMappingTests {
  @Test(
    "a connection never made is offline: nothing was sent",
    arguments: [
      URLError.Code.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ])
  func offlineCodes(code: URLError.Code) {
    guard case .Offline(let message) = TransportErrorMapping.map(URLError(code)) else {
      Issue.record("\(code) should map to offline")
      return
    }
    #expect(message == URLError(code).localizedDescription)
    guard case .offline = TransportErrorMapping.connectionFailure(from: URLError(code)) else {
      Issue.record("\(code) should end a stream as offline")
      return
    }
  }

  @Test("a connection lost mid-request may have sent it, and still ends a stream as offline")
  func aLostConnectionIsNotKnownUnsent() {
    let lost = URLError(.networkConnectionLost)
    guard case .Other(let message) = TransportErrorMapping.map(lost) else {
      Issue.record("a request's lost connection should map to other")
      return
    }
    let code = URLError.Code.networkConnectionLost.rawValue
    #expect(message == "\(lost.localizedDescription) (URLError \(code))")
    #expect(
      TransportErrorMapping.connectionFailure(from: lost)
        == .offline(message: lost.localizedDescription))
  }

  @Test func timedOutMapsToTimeout() {
    guard case .Timeout = TransportErrorMapping.map(URLError(.timedOut)) else {
      Issue.record("timedOut should map to timeout")
      return
    }
  }

  @Test func cancellations() {
    guard case .Cancelled = TransportErrorMapping.map(URLError(.cancelled)) else {
      Issue.record("URLError.Cancelled should map to cancelled")
      return
    }
    guard case .Cancelled = TransportErrorMapping.map(CancellationError()) else {
      Issue.record("CancellationError should map to cancelled")
      return
    }
  }

  @Test(arguments: [
    URLError.Code.secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
    .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
    .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection,
  ])
  func tlsCodes(code: URLError.Code) {
    guard case .Tls = TransportErrorMapping.map(URLError(code)) else {
      Issue.record("\(code) should map to tls")
      return
    }
  }

  @Test func otherCodesKeepDescription() {
    guard case .Other(let message) = TransportErrorMapping.map(URLError(.badServerResponse)) else {
      Issue.record("badServerResponse should map to other")
      return
    }
    #expect(message.contains("URLError \(URLError.Code.badServerResponse.rawValue)"))
  }

  @Test func nonURLErrorsMapToOther() {
    struct Boom: Error {}
    guard case .Other(let message) = TransportErrorMapping.map(Boom()) else {
      Issue.record("arbitrary errors should map to other")
      return
    }
    #expect(message.contains("Boom"))
  }
}
