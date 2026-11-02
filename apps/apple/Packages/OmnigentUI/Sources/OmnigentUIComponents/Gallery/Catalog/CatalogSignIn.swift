import OmnigentAuthUI
import SwiftUI

/// Sign-in: every connection and sign-in screen, the window-sized page, and the first-launch
/// flow from the server picker to the session list.
enum SignInCatalog {
  static var entries: [CatalogEntry] {
    [
      .component(
        .signIn, "screens", "Sign-in Screens",
        summary: "Every connection and sign-in state, as a sheet.",
        systemImage: "person.badge.key", canvas: .fixed(width: 560, height: 720),
        keywords: ["connect", "server", "password", "oidc", "databricks", "error"],
        states: AuthSamples.all.map { sample in
          CatalogState(sample.id, sample.title) {
            AuthFlowView(
              state: sample.state, actions: .inert, validator: .preview, presentation: .sheet)
          }
        }),
      .component(
        .signIn, "account-chip", "Account Chip",
        summary: "The signed-in account in the toolbar.",
        systemImage: "person.crop.circle", canvas: .column(width: 360),
        keywords: ["account", "sign out"],
        states: [
          CatalogState("chip", "Signed in") {
            CatalogStack { AccountChip(account: AuthSamples.account, actions: .inert) }
          }
        ]),
      .page(
        .signIn, "connect", "Connect and Sign In",
        summary: "The first window: choose a server, then sign in.",
        systemImage: "person.badge.key",
        keywords: ["first launch", "server picker", "connect"],
        states: ["picker", "picker-unreachable", "discovering", "password", "browser", "ticket"]
          .compactMap(AuthSamples.sample)
          .map { sample in
            CatalogState(sample.id, sample.title) {
              AuthFlowView(state: sample.state, actions: .inert, validator: .preview)
            }
          }),
      .flow(
        .signIn, "first-launch", "First Launch to Sessions",
        summary: "Open the app, connect to a server, sign in and land on the session list.",
        systemImage: "door.left.hand.open", keywords: ["first launch", "connect", "sign in"],
        script: firstLaunch),
    ]
  }

  typealias Step = CatalogFlowScript<SignInFlowModel>.Step

  static var firstLaunch: CatalogFlowScript<SignInFlowModel> {
    CatalogFlowScript(
      initial: { context in SignInFlowModel(context: context) },
      steps: [
        Step(
          "picker", "First launch", note: "No server yet: the picker offers your organization's."),
        Step("connect", "Connect", note: "Return or Connect discovers the server.") { model in
          model.auth.connect(to: AuthSamples.accountsUrl)
        },
        Step("sign-in", "Sign in", note: "This server signs in with an account.") { model in
          model.auth = sample("password")
        },
        Step(
          "submitting", "Signing in", note: "The form stays while the password is checked."
        ) { model in
          model.auth = sample("password-submitting")
        },
        Step(
          "wrong-password", "Wrong password", note: "The server's reason, verbatim.",
          branchesFrom: "sign-in"
        ) { model in
          model.auth = sample("password-error")
        },
        Step(
          "confirming", "Confirming identity", note: "The credential is checked.",
          branchesFrom: "submitting"
        ) { model in
          model.auth = sample("connecting")
        },
        Step(
          "sessions", "Session list", note: "Signed in: the shell opens on New Session."
        ) { model in
          model.isSignedIn = true
        },
      ],
      render: { model, context in AnyView(SignInFlowScreen(model: model, screen: context.screen)) }
    )
  }

  private static func sample(_ id: String) -> AuthViewState {
    AuthSamples.sample(id)?.state ?? AuthViewState()
  }
}

/// The first-launch flow's state: the sign-in state until signed in, then the shell.
struct SignInFlowModel {
  var auth = AuthViewState(directory: AuthSamples.directory, lastServerUrl: "")
  var isSignedIn = false
  let page: PlaygroundModel

  init(context: CatalogContext) {
    page = PlaygroundModel(scenario: .newSession, preferences: context.preferences)
  }
}

extension AuthViewState {
  /// What the store does on Connect: remember the server and start discovering it.
  mutating func connect(to serverUrl: String) {
    lastServerUrl = serverUrl
    phase = .discovering(serverUrl: serverUrl)
  }
}

private struct SignInFlowScreen: View {
  @Binding var model: SignInFlowModel
  let screen: CatalogScreen

  var body: some View {
    if model.isSignedIn {
      CatalogShell(model: model.page, screen: screen)
    } else {
      AuthFlowView(
        state: model.auth,
        actions: AuthActions(
          connect: { model.auth.connect(to: $0) },
          submitCredentials: { _ in
            model.auth = AuthSamples.sample("password-submitting")?.state ?? model.auth
          },
          startBrowserSignIn: { _ in }, cancel: { model.auth.phase = .disconnected },
          signOut: { model.isSignedIn = false }, retry: {}, forgetServer: { _ in }),
        validator: .preview)
    }
  }
}
