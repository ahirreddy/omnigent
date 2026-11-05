public import SwiftUI

/// The whole sign-in and connection flow for one ``AuthViewState``: it picks the screen from
/// ``AuthViewState/screen`` and lays it out for a window or a sheet.
///
/// Each screen is also public on its own (``ServerPickerView``, ``PasswordSignInView``, ...) for
/// hosts that compose them differently.
public struct AuthFlowView: View {
  private let state: AuthViewState
  private let actions: AuthActions
  private let validator: ServerURLValidator
  private let presentation: AuthPresentation

  /// Creates the flow.
  /// - Parameters:
  ///   - state: What to render.
  ///   - actions: The store's actions.
  ///   - validator: Checks typed server URLs with the core's normalizer.
  ///   - presentation: A window or a sheet.
  public init(
    state: AuthViewState, actions: AuthActions, validator: ServerURLValidator,
    presentation: AuthPresentation = .window
  ) {
    self.state = state
    self.actions = actions
    self.validator = validator
    self.presentation = presentation
  }

  /// The flow.
  public var body: some View {
    AuthContainer(presentation: presentation) {
      AuthScreenView(
        screen: state.screen, state: state, actions: actions, validator: validator)
    }
  }
}

/// One screen, without a container.
struct AuthScreenView: View {
  let screen: AuthScreen
  let state: AuthViewState
  let actions: AuthActions
  let validator: ServerURLValidator

  var body: some View {
    switch screen {
    case .serverPicker(let banner):
      OnboardingFlowView(
        directory: state.directory, prefill: state.prefillServerUrl, banner: banner,
        localSetup: state.localSetup, validator: validator, actions: actions)
    case .discovering(let serverUrl):
      ConnectingView(title: "Connecting\u{2026}", serverUrl: serverUrl, actions: actions)
    case .password(let server, let banner, let isSubmitting):
      PasswordSignInView(
        server: server, banner: banner, isSubmitting: isSubmitting, actions: actions)
    case .createAccount(let server, let form, let banner, let isSubmitting):
      CreateAccountView(
        server: server, form: form, banner: banner, isSubmitting: isSubmitting,
        inviteLink: state.inviteLink, actions: actions)
    case .browserSignIn(let server, let option, let alternatives, let banner):
      BrowserSignInView(
        server: server, option: option, alternatives: alternatives, banner: banner,
        actions: actions)
    case .reauthenticate(let server, let cause, let option):
      ReauthPromptView(server: server, cause: cause, option: option, actions: actions)
    case .workspaceSignIn(let server, let workspaceHost, let banner, let isSigningIn):
      WorkspaceSignInView(
        server: server, workspaceHost: workspaceHost, banner: banner, isSigningIn: isSigningIn,
        actions: actions)
    case .signingIn(let server, let option):
      SigningInView(server: server, option: option, actions: actions)
    case .awaitingBrowserApproval(let server, let approval):
      BrowserApprovalView(server: server, approval: approval, actions: actions)
    case .connecting(let server):
      ConnectingView(
        title: "Confirming your account\u{2026}", serverUrl: server.baseUrl, actions: actions)
    case .unsupported(let server, let mode):
      UnsupportedModeView(server: server, mode: mode, actions: actions)
    case .signedIn(let account):
      SignedInView(account: account, actions: actions)
    }
  }
}
