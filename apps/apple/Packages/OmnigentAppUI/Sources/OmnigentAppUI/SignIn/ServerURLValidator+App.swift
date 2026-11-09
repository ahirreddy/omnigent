import Foundation
public import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentStores

extension ServerURLValidator {
  /// The picker's live check with the core's normalizer and this build's URL policy (Debug
  /// accepts `http` to any host; Release requires `https` except for loopback), so the hint
  /// shows exactly what connecting will use.
  public static let app = Self { raw in
    #if DEBUG
      let policy = UrlPolicy.development
    #else
      let policy = UrlPolicy.release
    #endif
    do {
      return .success(try normalizeServerUrl(serverUrl: raw, policy: policy))
    } catch {
      return .failure(ServerURLRejection(message: thrownByCore(error).message))
    }
  }
}

/// What a core call threw. Its calls declare only `throws`, and only ever throw ``CoreError``.
nonisolated func thrownByCore(_ error: any Error) -> CoreError {
  error as? CoreError ?? .InvalidState(message: String(describing: error))
}
