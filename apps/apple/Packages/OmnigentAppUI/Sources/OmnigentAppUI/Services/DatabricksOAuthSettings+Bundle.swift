public import Foundation
public import OmnigentCoreFFI

extension DatabricksOAuthSettings {
  /// Info.plist key for the public OAuth client id (as in `web/ios`).
  public static let clientIDKey = "DatabricksOAuthClientID"
  /// Info.plist key for the exact HTTPS redirect registered with that client.
  public static let redirectURLKey = "DatabricksOAuthRedirectURL"

  /// The Databricks workspace OAuth client this build carries, or `nil` when the bundle has
  /// none (Databricks servers then offer no native sign-in, which the sign-in screen says).
  /// - Parameter bundle: Normally `.main`.
  /// - Returns: The settings.
  public static func bundled(_ bundle: Bundle = .main) -> Self? {
    guard let clientID = bundle.object(forInfoDictionaryKey: clientIDKey) as? String,
      let redirect = bundle.object(forInfoDictionaryKey: redirectURLKey) as? String,
      !clientID.isEmpty, !redirect.isEmpty
    else { return nil }
    return Self(clientId: clientID, redirectUrl: redirect)
  }
}
