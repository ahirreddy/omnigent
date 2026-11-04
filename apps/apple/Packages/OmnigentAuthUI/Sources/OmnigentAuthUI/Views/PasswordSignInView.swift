public import SwiftUI

/// The accounts-mode form: username and password.
///
/// The fields carry `textContentType(.username)` and `.password`, so the system offers saved
/// passwords (and, on iOS, the password AutoFill bar). Accounts mode has no WebAuthn endpoint, so
/// passkeys apply only to browser sign-in, where the system sheet shares Safari's passkeys.
///
/// Return in the username field moves to the password; Return in the password field signs in.
/// The password is cleared once submitted and when the form goes away, and never logged.
public struct PasswordSignInView: View {
  private let server: ServerIdentity
  private let banner: AuthBanner?
  private let isSubmitting: Bool
  private let actions: AuthActions

  @State private var username = ""
  @State private var password = ""
  @FocusState private var focus: Field?
  @Environment(\.openURL) private var openURL

  private enum Field: Hashable {
    case username
    case password
  }

  /// Creates the form.
  /// - Parameters:
  ///   - server: The server to sign in to.
  ///   - banner: The last failure or a notice.
  ///   - isSubmitting: Whether the sign-in is running.
  ///   - actions: The store's actions.
  public init(
    server: ServerIdentity, banner: AuthBanner?, isSubmitting: Bool, actions: AuthActions
  ) {
    self.server = server
    self.banner = banner
    self.isSubmitting = isSubmitting
    self.actions = actions
  }

  /// The form.
  public var body: some View {
    AuthCard(
      systemImage: "person.badge.key", title: "Sign in",
      subtitle: "Use your account on this server."
    ) {
      ServerSummary(server: server)
      if server.needsSetup {
        setupNotice
      }
      if let banner {
        AuthBannerView(banner, title: bannerTitle, retry: actions.retry)
      }
      fields
      createAccountLink
    } buttons: {
      AuthButton(
        title: "Use Another Server", kind: .cancel, identifier: "auth.cancel",
        action: actions.cancel)
      AuthButton(
        title: isSubmitting ? "Signing In\u{2026}" : "Sign In", kind: .primary,
        isBusy: isSubmitting, identifier: "auth.sign-in", action: submit
      )
      .disabled(
        !CredentialsInput.canSubmit(
          username: username, password: password, isSubmitting: isSubmitting))
    }
    .defaultFocus($focus, .username)
    .onDisappear { password = "" }
  }

  private var bannerTitle: String? {
    guard case .error(let error) = banner else { return nil }
    switch error.failure {
    case .signInRequired, .refused: return "Couldn\u{2019}t sign in"
    case .expired, .endedByServer, .transport, .failed, nil: return nil
    }
  }

  private var fields: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: AuthMetrics.fieldSpacing) {
        Text("Username")
          .font(.callout.weight(.medium))
          .accessibilityHidden(true)
        TextField("Username", text: $username)
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .textContentType(.username)
          .autocorrectionDisabled()
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .submitLabel(.next)
          #endif
          .focused($focus, equals: .username)
          .onSubmit { handleReturn(fromPassword: false) }
          .accessibilityLabel("Username")
          .accessibilityIdentifier("auth.username")
      }
      VStack(alignment: .leading, spacing: AuthMetrics.fieldSpacing) {
        Text("Password")
          .font(.callout.weight(.medium))
          .accessibilityHidden(true)
        SecureField("Password", text: $password)
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .textContentType(.password)
          #if os(iOS)
            .submitLabel(.go)
          #endif
          .focused($focus, equals: .password)
          .onSubmit { handleReturn(fromPassword: true) }
          .accessibilityLabel("Password")
          .accessibilityIdentifier("auth.password")
      }
    }
    .disabled(isSubmitting)
  }

  private var setupNotice: some View {
    VStack(alignment: .leading, spacing: 8) {
      AuthBannerView(
        .notice("This server has no administrator yet. Create the admin account to set it up."))
      HStack {
        Button("Create Admin Account\u{2026}", systemImage: "person.badge.shield.checkmark") {
          actions.showAccountForm(.createAdmin)
        }
        .accessibilityIdentifier("auth.create-admin")
        if let url = server.webURL {
          Button("Open Setup in Browser", systemImage: "safari") { openURL(url) }
            .accessibilityIdentifier("auth.open-setup")
        }
      }
      .controlSize(.small)
    }
  }

  /// Registration is by invite: the admin sends a link, which the form below accepts.
  private var createAccountLink: some View {
    HStack(spacing: 4) {
      Text("Have an invite?")
        .foregroundStyle(.secondary)
      Button("Create an account") { actions.showAccountForm(.register) }
        #if os(macOS)
          .buttonStyle(.link)
        #else
          .buttonStyle(.borderless)
        #endif
        .accessibilityIdentifier("auth.show-register")
    }
    .font(.callout)
    .disabled(isSubmitting)
  }

  private func handleReturn(fromPassword: Bool) {
    switch CredentialsInput.returnStep(
      fromPassword: fromPassword, username: username, password: password,
      isSubmitting: isSubmitting)
    {
    case .submit: submit()
    case .focusPassword: focus = .password
    case .focusUsername: focus = .username
    case .none: break
    }
  }

  private func submit() {
    guard
      CredentialsInput.canSubmit(username: username, password: password, isSubmitting: isSubmitting)
    else { return }
    let credentials = AccountCredentials(username: username, password: password)
    password = ""
    focus = .password
    actions.submitCredentials(credentials)
  }
}
