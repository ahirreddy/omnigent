import Foundation
public import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentStores

/// This Mac's local server, as "Get started locally" uses it. The Mac app supplies one
/// (``LocalServerSetup``); other platforms leave ``SignInController/localSetup`` `nil`.
public protocol LocalSetupSource: AnyObject {
  /// The CLI and server, for the local setup screens.
  var state: LocalSetupState { get }
  /// The screens' actions; `connect` connects the window once the server is ready.
  /// - Parameter connect: Connects the window to a server URL.
  /// - Returns: The actions.
  func actions(connect: @escaping @MainActor (String) -> Void) -> LocalSetupActions
  /// The window signed in to `baseUrl`: start hosting there if the user asked to.
  /// - Parameter baseUrl: The server signed in to.
  func didSignIn(to baseUrl: String)
}

/// Account creation, server probes and the local setup hand-off.
extension SignInController {
  /// Creates the account `request` describes and signs in with it, or shows why not.
  func createAccount(_ request: AccountCreationRequest) {
    flowError = nil
    notice = nil
    method = .password
    let invite: String? =
      switch request.kind {
      case .firstAdmin: nil
      case .invited(let token): token
      }
    Task {
      let before = store.issues.count
      let server = await store.createAccount(
        invite: invite, username: request.credentials.username,
        password: request.credentials.password)
      method = nil
      signedIn(server, issuesBefore: before)
    }
  }

  /// Opens Create Account with `link`, an invite to the server this controller connects to.
  /// - Parameter link: The invite link (`…/register?invite=<token>`).
  public func openInvite(_ link: String) {
    inviteLink = link
    flowError = nil
    if store.connectedServer == nil { accountForm = .register }
  }

  /// The server of an invite link (`https://host/mount/register?invite=<token>` →
  /// `https://host/mount`), or `nil` when `text` is not one.
  nonisolated static func inviteServer(_ text: String) -> String? {
    guard inviteTokenFromLink(text: text) != nil, var components = URLComponents(string: text),
      components.scheme != nil, components.path.hasSuffix("/register")
    else { return nil }
    components.path.removeLast("/register".count)
    components.query = nil
    components.fragment = nil
    return components.string
  }

  /// Switches the accounts screen between signing in and creating an account.
  func showAccountForm(_ form: AccountForm) {
    flowError = nil
    accountForm = form
  }

  /// Whether `serverURL` answers as an Omnigent server, for the server list. Reading the
  /// manifest is unauthenticated and leaves the connection alone.
  func checkServer(_ serverURL: String) async -> ServerReachability {
    guard let core = store.core else { return .unreachable }
    do {
      let discovery = try await core.discoverServer(serverUrl: serverURL)
      // A 404 manifest still discovers; without a version or auth mode nothing says Omnigent.
      if discovery.serverVersion == nil && discovery.authMode == nil { return .reachable }
      return .omnigent(name: discovery.serverName)
    } catch {
      switch thrownByCore(error) {
      case .HttpStatus, .Decode: return .reachable
      default: return .unreachable
      }
    }
  }

  /// A connect or sign-in in this window reached `server`.
  func signedInHere(_ server: ConnectedServer) {
    inviteLink = nil
    localSetup?.didSignIn(to: server.baseUrl)
    onSignedIn(server)
  }
}
