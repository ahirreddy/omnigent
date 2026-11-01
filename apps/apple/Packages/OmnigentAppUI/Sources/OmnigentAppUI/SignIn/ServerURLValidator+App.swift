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
    } catch let error as CoreError {
      return .failure(ServerURLRejection(message: error.message))
    } catch {
      return .failure(ServerURLRejection(message: String(describing: error)))
    }
  }
}
