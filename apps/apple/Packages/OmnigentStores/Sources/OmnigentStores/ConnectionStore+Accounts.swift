public import OmnigentCoreFFI

extension ConnectionStore {
  /// Creates an accounts-mode account and signs in with it: the server's first administrator
  /// when `invite` is `nil`, otherwise an invited user.
  /// - Parameters:
  ///   - invite: The invite token, or `nil` for the first administrator.
  ///   - username: The account name.
  ///   - password: The password; it is not kept.
  /// - Returns: The server signed in to, or `nil` after recording the failure.
  public func createAccount(invite: String?, username: String, password: String) async
    -> ConnectedServer?
  {
    guard let core else { return nil }
    do {
      if let invite {
        return try await core.registerAccount(
          invite: invite, username: username, password: password)
      }
      return try await core.createFirstAdmin(username: username, password: password)
    } catch {
      record(scope: .connection, coreError(error))
      return nil
    }
  }
}
