import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentServices

struct TransportErrorMappingTests {
  @Test(arguments: [
    URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
  ])
  func offlineCodes(code: URLError.Code) {
    guard case .Offline = TransportErrorMapping.map(URLError(code)) else {
      Issue.record("\(code) should map to offline")
      return
    }
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
