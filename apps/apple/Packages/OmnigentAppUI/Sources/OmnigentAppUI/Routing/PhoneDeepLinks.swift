#if os(iOS)
  public import Foundation
  import OmnigentAuthUI
  import OmnigentDeepLinks
  import OmnigentStores
  public import OmnigentUIComponents
  public import SwiftUI

  extension View {
    /// Opens `omnigent://host/c/<id>`, `omnigent://host`, page (`/usage`), `/settings` and
    /// `…/register?invite=` links in this scene: in place on its server, after moving to a
    /// recent server, or after the user agrees to connect to a new one. A link to another server
    /// supersedes a launch reconnect still in flight. Apply it inside `phoneSupervision`, whose
    /// Settings screen settings links open; pairing codes are left to
    /// ``phoneSupervision(_:session:selection:scenePhase:)``.
    /// - Parameters:
    ///   - session: The scene's session.
    ///   - restoringServer: The server the launch is reconnecting to, before the core reports it.
    ///   - selection: The scene's destination.
    ///   - knownServers: Servers the user connected to before.
    ///   - switchServer: Moves the scene to a server.
    ///   - launchLink: A link to open once the scene is ready, as if the system had opened it.
    /// - Returns: The view.
    public func phoneDeepLinks(
      session: ServerSession?, restoringServer: URL? = nil,
      selection: Binding<SidebarDestination?>, knownServers: [URL],
      switchServer: @escaping @MainActor (URL) -> Void, launchLink: URL? = nil
    ) -> some View {
      modifier(
        PhoneDeepLinks(
          session: session, restoringServer: restoringServer, selection: selection,
          knownServers: knownServers, switchServer: switchServer, launchLink: launchLink))
    }
  }

  struct PhoneDeepLinks: ViewModifier {
    let session: ServerSession?
    let restoringServer: URL?
    @Binding var selection: SidebarDestination?
    let knownServers: [URL]
    let switchServer: @MainActor (URL) -> Void
    let launchLink: URL?

    @State private var openedLaunchLink = false

    /// A link that arrived before the scene's session was ready to route it.
    @State private var waiting: OmnigentDeepLink?
    /// A route waiting for the scene to sign in to its server.
    @State private var pending: (route: OmnigentDeepLinks.DeepLinkRoute, origin: ServerOrigin)?
    /// A link to a never-used server, while the user decides.
    @State private var consent: OmnigentDeepLink?
    @State private var problem: String?
    /// The scene's Settings screen, for `/settings` links.
    @Environment(\.openSettingsAt) private var openSettingsAt

    /// The scene's server while it is signed in.
    private var readyServer: URL? {
      session?.isSignedIn == true ? session?.connectedURL : nil
    }

    func body(content: Content) -> some View {
      content
        .onOpenURL(perform: received)
        .onChange(of: session == nil, initial: true) {
          if session != nil, let launchLink, !openedLaunchLink {
            openedLaunchLink = true
            received(launchLink)
          }
          routeWaiting()
        }
        .onChange(of: readyServer) { deliverPending() }
        .alert(
          "Open this Omnigent link?",
          isPresented: Binding(get: { consent != nil }, set: { if !$0 { consent = nil } }),
          presenting: consent
        ) { link in
          Button("Cancel", role: .cancel) { consent = nil }
          Button("Open") {
            consent = nil
            open(link)
          }
        } message: { link in
          Text(
            """
            This link will connect Omnigent to \(link.origin.authority). Only open links from \
            a server you trust. Once connected, it can show notifications.
            """)
        }
        .alert(
          "Can\u{2019}t Open This Link",
          isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
        ) {
          Button("OK", role: .cancel) { problem = nil }
        } message: {
          Text(problem ?? "")
        }
    }

    private func received(_ url: URL) {
      guard !Self.isPairingCode(url) else { return }
      let link: OmnigentDeepLink
      do {
        link = try OmnigentDeepLink(parsing: url.absoluteString)
      } catch {
        problem = "\(url.absoluteString) isn\u{2019}t an Omnigent link this app can open."
        return
      }
      if session == nil {
        waiting = link
      } else {
        route(link)
      }
    }

    private func routeWaiting() {
      guard session != nil, let link = waiting else { return }
      waiting = nil
      route(link)
    }

    private func route(_ link: OmnigentDeepLink) {
      guard let session else { return }
      let plan = SceneLinkPlan.plan(
        link, sceneServer: session.targetURL ?? restoringServer, isReady: readyServer != nil,
        knownServers: knownServers)
      switch plan {
      case .apply(let route):
        apply(route, server: session.targetURL ?? link.origin.url)
      case .applyWhenReady(let route):
        pending = (route, link.origin)
      case .switchServer(let url, let route):
        move(to: url, then: route, origin: link.origin)
      case .confirm:
        consent = link
      }
    }

    /// The user agreed to connect to the link's server.
    private func open(_ link: OmnigentDeepLink) {
      guard let url = link.origin.url else {
        problem = "\(link.origin.authority) isn\u{2019}t a server address this app can open."
        return
      }
      move(to: url, then: link.route, origin: link.origin)
    }

    private func move(
      to server: URL, then route: OmnigentDeepLinks.DeepLinkRoute, origin: ServerOrigin
    ) {
      guard let session else { return }
      if case .register(let invite) = route,
        let link = SceneLinkPlan.inviteLink(server: server, invite: invite)
      {
        // Connecting with the invite link opens Create Account with it.
        session.connection.disconnect()
        selection = nil
        session.signIn.connect(link)
        return
      }
      pending = (route, origin)
      switchServer(server)
    }

    private func deliverPending() {
      guard let pending, let server = readyServer, ServerOrigin(validURL: server) == pending.origin
      else { return }
      self.pending = nil
      apply(pending.route, server: server)
    }

    private func apply(_ route: OmnigentDeepLinks.DeepLinkRoute, server: URL?) {
      switch route {
      case .home:
        selection = nil
      case .conversation(let sessionID):
        selection = .session(sessionID)
      case .page(let page):
        selection = DeepLinkDestinations.selection(for: page)
      case .settings(let section):
        // The screen shows the scene's own server.
        openSettingsAt?(DeepLinkDestinations.settings(section: section, server: nil))
      case .register(let invite):
        guard let server, let link = SceneLinkPlan.inviteLink(server: server, invite: invite)
        else { return }
        session?.signIn.openInvite(link)
      }
    }

    /// Pairing codes, valid or not, belong to the pairing confirmation.
    private static func isPairingCode(_ url: URL) -> Bool {
      do {
        _ = try PairingCode(parsing: url.absoluteString)
        return true
      } catch .notAPairingCode {
        return false
      } catch {
        return true
      }
    }
  }
#endif
