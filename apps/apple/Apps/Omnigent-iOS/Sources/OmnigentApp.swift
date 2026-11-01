import OSLog
import OmnigentAppUI
import OmnigentAuthUI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

@main
struct OmnigentApp: App {
  @State private var theme = ThemePreferences()

  var body: some Scene {
    WindowGroup {
      IOSRootView()
        .omnigentTheme(theme.theme, appearance: theme.mode)
    }
  }
}

/// The iPhone and iPad root: the same assembly as the Mac windows, as one scene. The split view
/// collapses to a stack on compact width. The last server is reconnected on launch.
struct IOSRootView: View {
  static let lastServerKey = "omnigent.lastServer"
  static let recentServersKey = "omnigent.recentServers"

  @State private var session: ServerSession?
  @State private var selection: SidebarDestination?
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Group {
      if let session {
        ServerRootView(session: session, selection: $selection)
      } else {
        ProgressView()
      }
    }
    .task { await start() }
    .onChange(of: scenePhase) { previous, phase in
      // Back from the background: streams reopen and reconcile. Launch (inactive to active)
      // is not a return; the first connect opens the streams.
      if previous == .background, phase != .background, session?.isSignedIn == true {
        session?.connection.foreground()
      }
    }
  }

  private func start() async {
    guard session == nil else { return }
    let session: ServerSession
    if ProcessInfo.processInfo.arguments.contains("-OmnigentDemo") {
      do {
        session = try ServerSession.demo()
      } catch {
        Logger(subsystem: "ai.omnigent.ios", category: "app").error(
          "The demo server did not load: \(String(describing: error), privacy: .public)")
        session = ServerSession.live(keychain: KeychainModeSelection.current())
      }
    } else {
      session = ServerSession.live(keychain: KeychainModeSelection.current())
    }
    let defaults = UserDefaults.standard
    session.signIn.directory = ServerDirectory(
      recentServers: defaults.stringArray(forKey: Self.recentServersKey) ?? [])
    session.signIn.onServerChange = { url in
      guard let url else {
        defaults.removeObject(forKey: Self.lastServerKey)
        selection = nil
        return
      }
      defaults.set(url.absoluteString, forKey: Self.lastServerKey)
      var recents = defaults.stringArray(forKey: Self.recentServersKey) ?? []
      recents.removeAll { $0 == url.absoluteString }
      recents.insert(url.absoluteString, at: 0)
      defaults.set(Array(recents.prefix(10)), forKey: Self.recentServersKey)
      session.signIn.directory = ServerDirectory(recentServers: recents)
    }
    session.signIn.forgetServer = { url in
      var recents = defaults.stringArray(forKey: Self.recentServersKey) ?? []
      recents.removeAll { $0 == url }
      defaults.set(recents, forKey: Self.recentServersKey)
      session.signIn.directory = ServerDirectory(recentServers: recents)
    }
    self.session = session
    if let last = defaults.string(forKey: Self.lastServerKey) {
      await session.signIn.connectNow(last)
    }
  }
}
