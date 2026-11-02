import OSLog
import OmnigentAppUI
import OmnigentAuthUI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

@main
struct OmnigentApp: App {
  @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
  @State private var theme = ThemePreferences()

  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if let gallery = Self.gallery {
          // Debug builds launched with -OmnigentGallery show the component gallery instead.
          GalleryCatalogView(options: gallery)
        } else {
          IOSRootView()
            .appearanceSettings(theme)
            .omnigentTheme(theme.theme, appearance: theme.mode)
        }
      #else
        IOSRootView()
          .appearanceSettings(theme)
          .omnigentTheme(theme.theme, appearance: theme.mode)
      #endif
    }
    .commands {
      OmnigentSessionCommands()
      OmnigentTabCommands()
    }
  }

  #if DEBUG
    /// The gallery's launch options when `-OmnigentGallery` asked for it; a bad option is logged
    /// and the app starts normally.
    private static let gallery: GalleryLaunchOptions? = {
      do {
        let options = try GalleryLaunchOptions(
          arguments: ProcessInfo.processInfo.arguments,
          environment: ProcessInfo.processInfo.environment)
        return options.showsGallery ? options : nil
      } catch {
        Logger(subsystem: "ai.omnigent.ios", category: "gallery").error(
          "Gallery launch options: \(String(describing: error), privacy: .public)")
        return nil
      }
    }()
  #endif
}

/// The iPhone and iPad root: the same assembly as the Mac windows, as one scene. The split view
/// collapses to a stack on compact width. The last server is reconnected on launch.
struct IOSRootView: View {
  static let lastServerKey = "omnigent.lastServer"
  static let recentServersKey = "omnigent.recentServers"

  /// Saves each scene's tabs; `nil` when Application Support is unavailable.
  static let tabPersistence: TabPersistence? = {
    do {
      return try TabPersistence.applicationSupport(
        bundleID: Bundle.main.bundleIdentifier ?? "ai.omnigent.ios")
    } catch {
      Logger(subsystem: "ai.omnigent.ios", category: "app").error(
        "Tabs will not be saved: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }()

  @State private var session: ServerSession?
  @State private var selection: SidebarDestination?
  /// The scene's stable id, so iPad windows each restore their own tabs.
  @SceneStorage("omnigent.tabs.window") private var windowID = ""
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Group {
      if let session {
        // Read state marks a session seen only while the scene is on screen.
        ServerRootView(
          session: session, selection: $selection, isWindowFocused: scenePhase == .active,
          tabContext: TabWindowContext(
            window: UUID(uuidString: windowID) ?? UUID(), persistence: Self.tabPersistence))
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
      // iOS may end a backgrounded app without notice: save the tabs now.
      if phase == .background { Self.tabPersistence?.flush() }
    }
    .phoneSupervision(
      PhoneAppDelegate.supervision, session: session, selection: $selection,
      scenePhase: scenePhase)
  }

  private func start() async {
    guard session == nil else { return }
    if UUID(uuidString: windowID) == nil { windowID = UUID().uuidString }
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
    // The demo always opens to its own sessions, whatever server the device last used.
    if let server = session.isDemo
      ? ServerSession.demoServerURL : defaults.string(forKey: Self.lastServerKey)
    {
      await session.signIn.connectNow(server)
    }
  }
}
