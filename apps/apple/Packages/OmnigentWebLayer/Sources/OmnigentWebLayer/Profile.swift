internal import CryptoKit
public import Foundation
public import Observation

/// Per-profile browser state in the host: cookies, storage and cache. Views in one profile share
/// them; different profiles are isolated. Backed by one `CefRequestContext` in the host.
@Observable
public final class Profile {
  /// How long profile data lives.
  public enum Persistence: Sendable, Hashable {
    /// On disk under the session's root cache directory, kept across launches.
    case persistent
    /// In memory in the host; gone when the profile closes or the host restarts.
    case ephemeral
  }

  /// Session-unique ID used on the wire.
  public let id: UInt64
  /// Caller-chosen identity, for example a server ID.
  public let identifier: String
  /// Whether data survives relaunch.
  public let persistence: Persistence
  /// The most recent host error for this profile, such as a failed context creation.
  public internal(set) var lastError: WebLayerError?
  /// Whether `close()` was called.
  public private(set) var isClosed = false

  @ObservationIgnored let session: Session

  init(session: Session, id: UInt64, identifier: String, persistence: Persistence) {
    self.session = session
    self.id = id
    self.identifier = identifier
    self.persistence = persistence
  }

  /// Filesystem-safe directory key derived from the identifier: the first 16 bytes of its
  /// SHA-256, hex encoded.
  public var storageKey: String {
    Self.storageKey(for: identifier)
  }

  /// Creates a view in this profile. It appears once the host is ready.
  public func makeWebView(initialURL: URL? = nil) -> WebView {
    let view = WebView(profile: self, id: session.allocateID(), initialURL: initialURL)
    session.register(view)
    return view
  }

  /// Closes every view in this profile and releases its storage in the host. Ephemeral data is
  /// discarded.
  public func close() {
    guard !isClosed else { return }
    isClosed = true
    for view in session.views.values where view.profile === self {
      view.close()
    }
    session.remove(self)
  }
}

/// The first 16 bytes of SHA-256, hex encoded.
nonisolated enum SHA256Digest16 {
  static func hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).prefix(16).map(\.hexByte).joined()
  }
}

extension UInt8 {
  /// Two lowercase hex digits.
  nonisolated var hexByte: String {
    let digits = String(self, radix: 16)
    return digits.count == 1 ? "0" + digits : digits
  }
}
