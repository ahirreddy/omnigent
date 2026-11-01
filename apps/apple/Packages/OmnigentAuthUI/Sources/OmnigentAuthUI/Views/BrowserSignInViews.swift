public import SwiftUI

/// The start of an OIDC browser sign-in: names the server and opens its sign-in page in the
/// system browser sheet, which shares Safari's saved passwords, passkeys and identity-provider
/// session.
public struct BrowserSignInView: View {
  private let server: ServerIdentity
  private let option: SignInOption
  private let alternatives: [SignInOption]
  private let banner: AuthBanner?
  private let actions: AuthActions

  /// Creates the view.
  /// - Parameters:
  ///   - server: The server to sign in to.
  ///   - option: The best browser option.
  ///   - alternatives: Other options, offered as secondary buttons.
  ///   - banner: A refusal, failure or notice.
  ///   - actions: The store's actions.
  public init(
    server: ServerIdentity, option: SignInOption, alternatives: [SignInOption],
    banner: AuthBanner?, actions: AuthActions
  ) {
    self.server = server
    self.option = option
    self.alternatives = alternatives
    self.banner = banner
    self.actions = actions
  }

  /// The view.
  public var body: some View {
    AuthCard(
      systemImage: "person.crop.circle.badge.checkmark", title: "Sign in", subtitle: subtitle
    ) {
      ServerSummary(server: server)
      if let banner {
        AuthBannerView(banner, retry: actions.retry)
      }
      if !alternatives.isEmpty {
        ForEach(alternatives, id: \.self) { alternative in
          Button(alternative.actionTitle, systemImage: "link") {
            actions.startBrowserSignIn(alternative)
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.tint)
          .accessibilityIdentifier("auth.alternative-sign-in")
        }
      }
    } buttons: {
      AuthButton(
        title: "Use Another Server", kind: .cancel, identifier: "auth.cancel",
        action: actions.cancel)
      AuthButton(title: option.actionTitle, kind: .primary, identifier: "auth.browser-sign-in") {
        actions.startBrowserSignIn(option)
      }
    }
  }

  private var subtitle: String {
    switch option {
    case .browserTicket:
      "A sign-in page opens in your browser. Approve the request there, then come back."
    case .password, .browser, .loopbackBrowser, .databricksWorkspace:
      "You\u{2019}ll continue in your browser, where your saved passwords and passkeys work."
    }
  }
}

/// "Signing in..." with Cancel, while the browser sign-in sheet is open or a saved sign-in renews.
/// Cancel, or closing the sheet, returns to the picker with the URL kept.
public struct SigningInView: View {
  private let server: ServerIdentity
  private let option: SignInOption?
  private let actions: AuthActions

  /// Creates the view.
  /// - Parameters:
  ///   - server: The server being signed in to.
  ///   - option: The option in progress, when known.
  ///   - actions: The store's actions.
  public init(server: ServerIdentity, option: SignInOption?, actions: AuthActions) {
    self.server = server
    self.option = option
    self.actions = actions
  }

  /// The view.
  public var body: some View {
    AuthCard(
      systemImage: "person.crop.circle", title: "Signing in\u{2026}", subtitle: subtitle,
      isProgress: true
    ) {
      ServerSummary(server: server)
    } buttons: {
      AuthButton(title: "Cancel", kind: .cancel, identifier: "auth.cancel", action: actions.cancel)
    }
    .accessibilityIdentifier("auth.signing-in")
  }

  private var subtitle: String {
    switch option {
    case .browser, .loopbackBrowser, .browserTicket, .databricksWorkspace:
      "Finish signing in to \(server.displayName) in the browser window."
    case .password, nil:
      "Signing in to \(server.displayName)."
    }
  }
}

/// A browser-ticket sign-in waiting for approval: the code to match, a button that opens the
/// approval page (whose URL carries the ticket, so it is never printed), and Cancel.
public struct BrowserApprovalView: View {
  private let server: ServerIdentity
  private let approval: BrowserApproval
  private let actions: AuthActions

  @Environment(\.openURL) private var openURL

  /// Creates the view.
  /// - Parameters:
  ///   - server: The server being signed in to.
  ///   - approval: The pending ticket.
  ///   - actions: The store's actions.
  public init(server: ServerIdentity, approval: BrowserApproval, actions: AuthActions) {
    self.server = server
    self.approval = approval
    self.actions = actions
  }

  /// The view.
  public var body: some View {
    AuthCard(
      systemImage: "checkmark.shield", title: "Approve in your browser",
      subtitle:
        "Approve the sign-in request on the page that opened. This window continues on its own."
    ) {
      ServerSummary(server: server)
      if let code = approval.userCode, !code.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Confirm the page shows this code")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(verbatim: ServerText.escaped(code, limit: 32))
            .font(.title.monospaced().weight(.semibold))
            .textSelection(.enabled)
            .accessibilityLabel(
              "Code \(ServerText.escaped(code, limit: 32).map(String.init).joined(separator: " "))"
            )
            .accessibilityIdentifier("auth.user-code")
        }
      }
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(
          "Waiting for approval\u{2026} The request expires at \(approval.expiresAt, style: .time)."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    } buttons: {
      AuthButton(title: "Cancel", kind: .cancel, identifier: "auth.cancel", action: actions.cancel)
      AuthButton(title: "Open Sign-In Page", kind: .primary, identifier: "auth.open-login") {
        if let url = URL(string: approval.loginUrl) { openURL(url) }
      }
      .disabled(URL(string: approval.loginUrl) == nil)
    }
  }
}

/// "Sign in again?": a saved sign-in stopped working. It names the cause (expired, ended by the
/// server, sign-in required) in the core's words, and only Sign In opens the browser.
public struct ReauthPromptView: View {
  private let server: ServerIdentity
  private let cause: ReauthCause
  private let option: SignInOption
  private let actions: AuthActions

  /// Creates the prompt.
  /// - Parameters:
  ///   - server: The server to sign in to again.
  ///   - cause: Why the saved sign-in stopped working.
  ///   - option: The option Sign In starts.
  ///   - actions: The store's actions.
  public init(
    server: ServerIdentity, cause: ReauthCause, option: SignInOption, actions: AuthActions
  ) {
    self.server = server
    self.cause = cause
    self.option = option
    self.actions = actions
  }

  /// The prompt.
  public var body: some View {
    AuthCard(systemImage: cause.systemImage, title: "Sign in again?", subtitle: cause.explanation) {
      ServerSummary(server: server)
    } buttons: {
      AuthButton(
        title: "Not Now", kind: .cancel, identifier: "auth.cancel", action: actions.cancel)
      AuthButton(title: "Sign In", kind: .primary, identifier: "auth.reauth-sign-in") {
        actions.startBrowserSignIn(option)
      }
    }
    .accessibilityIdentifier("auth.reauth")
  }
}

/// Databricks workspace sign-in: the workspace's own OAuth in the browser sheet.
public struct WorkspaceSignInView: View {
  private let server: ServerIdentity
  private let workspaceHost: String
  private let banner: AuthBanner?
  private let isSigningIn: Bool
  private let actions: AuthActions

  /// Creates the view.
  /// - Parameters:
  ///   - server: The Omnigent server inside the workspace.
  ///   - workspaceHost: The workspace host.
  ///   - banner: A failure or notice.
  ///   - isSigningIn: Whether the browser is open.
  ///   - actions: The store's actions.
  public init(
    server: ServerIdentity, workspaceHost: String, banner: AuthBanner?, isSigningIn: Bool,
    actions: AuthActions
  ) {
    self.server = server
    self.workspaceHost = workspaceHost
    self.banner = banner
    self.isSigningIn = isSigningIn
    self.actions = actions
  }

  /// The view.
  public var body: some View {
    AuthCard(
      systemImage: "building.columns",
      title: isSigningIn ? "Waiting for Databricks\u{2026}" : "Sign in with Databricks",
      subtitle: subtitle, isProgress: isSigningIn
    ) {
      ServerSummary(server: server)
      if let banner {
        AuthBannerView(banner, retry: actions.retry)
      }
    } buttons: {
      if isSigningIn {
        AuthButton(
          title: "Cancel", kind: .cancel, identifier: "auth.cancel", action: actions.cancel)
      } else {
        AuthButton(
          title: "Use Another Server", kind: .cancel, identifier: "auth.cancel",
          action: actions.cancel)
        AuthButton(
          title: SignInOption.databricksWorkspace(workspaceHost: workspaceHost).actionTitle,
          kind: .primary, identifier: "auth.workspace-sign-in"
        ) {
          actions.startBrowserSignIn(.databricksWorkspace(workspaceHost: workspaceHost))
        }
      }
    }
  }

  private var subtitle: String {
    let host = ServerText.escaped(workspaceHost, limit: 120)
    return isSigningIn
      ? "Finish signing in to \(host) in the browser window."
      : "This server runs in the Databricks workspace \(host). Sign in with your workspace account."
  }
}

/// Discovery or identity confirmation in progress, with Cancel.
public struct ConnectingView: View {
  private let title: String
  private let serverUrl: String
  private let actions: AuthActions

  /// Creates the view.
  /// - Parameters:
  ///   - title: What is happening, for example "Connecting...".
  ///   - serverUrl: The server.
  ///   - actions: The store's actions.
  public init(title: String, serverUrl: String, actions: AuthActions) {
    self.title = title
    self.serverUrl = serverUrl
    self.actions = actions
  }

  /// The view.
  public var body: some View {
    AuthCard(
      systemImage: "network", title: title,
      subtitle: ServerIdentity.hostLabel(serverUrl), isProgress: true
    ) {
      EmptyView()
    } buttons: {
      AuthButton(title: "Cancel", kind: .cancel, identifier: "auth.cancel", action: actions.cancel)
    }
    .accessibilityIdentifier("auth.connecting")
  }
}

/// A server whose sign-in this app cannot do natively, with a link to its web app.
public struct UnsupportedModeView: View {
  private let server: ServerIdentity
  private let mode: SignInMode
  private let actions: AuthActions

  @Environment(\.openURL) private var openURL

  /// Creates the explanation.
  /// - Parameters:
  ///   - server: The server.
  ///   - mode: Its sign-in mode.
  ///   - actions: The store's actions.
  public init(server: ServerIdentity, mode: SignInMode, actions: AuthActions) {
    self.server = server
    self.mode = mode
    self.actions = actions
  }

  /// The explanation.
  public var body: some View {
    AuthCard(
      systemImage: "lock.trianglebadge.exclamationmark",
      title: "Open this server in your browser", subtitle: explanation
    ) {
      ServerSummary(server: server)
    } buttons: {
      AuthButton(
        title: "Use Another Server", kind: .cancel, identifier: "auth.cancel",
        action: actions.cancel)
      if let url = server.webURL {
        AuthButton(title: "Open in Browser", kind: .primary, identifier: "auth.open-in-browser") {
          openURL(url)
        }
      }
    }
    .accessibilityIdentifier("auth.unsupported")
  }

  /// Why the app cannot sign in, by mode.
  var explanation: String {
    let name = server.displayName
    switch mode {
    case .proxy:
      return
        "\(name) gets your identity from a proxy in front of it, which this app can\u{2019}t sign in through yet."
    case .unsupported(let raw):
      return
        "\(name) uses the sign-in mode \u{201C}\(ServerText.escaped(raw, limit: 40))\u{201D}, which this version of the app doesn\u{2019}t support. Update the app, or use the server in your browser."
    case .accounts, .oidc, .localSingleUser:
      return "This app can\u{2019}t offer a sign-in method that \(name) accepts."
    }
  }
}
