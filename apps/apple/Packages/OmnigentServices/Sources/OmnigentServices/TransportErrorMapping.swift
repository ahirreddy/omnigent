public import Foundation
public import OmnigentCoreFFI

/// Maps Foundation networking errors onto the core's `TransportError`.
public enum TransportErrorMapping {
  /// Maps any error thrown while performing a request.
  /// - Parameter error: The error thrown by `URLSession` or the surrounding task.
  /// - Returns: The matching `TransportError`; unknown errors become `.Other` with their
  ///   description.
  public static func map(_ error: any Error) -> TransportError {
    if let transportError = error as? TransportError {
      return transportError
    }
    if error is CancellationError {
      return .Cancelled
    }
    if let urlError = error as? URLError {
      return map(urlError)
    }
    return .Other(message: String(describing: error))
  }

  /// Maps a `URLError` by code.
  /// - Parameter error: The URL loading error.
  /// - Returns: The matching `TransportError`.
  public static func map(_ error: URLError) -> TransportError {
    let message = error.localizedDescription
    switch error.code {
    case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
      return .Offline(message: message)
    case .timedOut:
      return .Timeout(message: message)
    case .cancelled:
      return .Cancelled
    case .secureConnectionFailed,
      .serverCertificateHasBadDate,
      .serverCertificateUntrusted,
      .serverCertificateHasUnknownRoot,
      .serverCertificateNotYetValid,
      .clientCertificateRejected,
      .clientCertificateRequired,
      .appTransportSecurityRequiresSecureConnection:
      return .Tls(message: message)
    default:
      return .Other(message: "\(message) (URLError \(error.code.rawValue))")
    }
  }
}
