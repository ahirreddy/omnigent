public import Foundation
public import OmnigentCoreFFI

/// Maps Foundation networking errors onto the core's `TransportError` and `ConnectionFailure`.
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
  /// - Returns: The matching `TransportError`. `.Offline` is only a connection never made, so
  ///   nothing was sent; a connection lost mid-request may have delivered it and is `.Other`.
  public static func map(_ error: URLError) -> TransportError {
    let message = error.localizedDescription
    switch error.code {
    case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
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

  /// Maps an error that ended a long-lived stream or socket.
  /// - Parameter error: The error reported by the task.
  /// - Returns: The matching `ConnectionFailure`. Platform authentication demands map to
  ///   `.authenticationRequired`, because the core never supplies credentials. A lost connection
  ///   is `.offline` here: a stream carries no request whose delivery could be in doubt.
  public static func connectionFailure(from error: any Error) -> ConnectionFailure {
    if let urlError = error as? URLError {
      switch urlError.code {
      case .userAuthenticationRequired, .userCancelledAuthentication:
        return .authenticationRequired(message: urlError.localizedDescription)
      case .networkConnectionLost:
        return .offline(message: urlError.localizedDescription)
      default:
        break
      }
    }
    switch map(error) {
    case .Offline(let message): return .offline(message: message)
    case .Timeout(let message): return .timeout(message: message)
    case .Cancelled: return .cancelled
    case .Tls(let message): return .tls(message: message)
    case .Other(let message): return .other(message: message)
    }
  }
}
