import AppKit
import Foundation
import OmnigentDesktop
import OmnigentUIComponents
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// What a launch decides on its own: the server a new window opens on, and what stays off.
@MainActor
struct LaunchDecisionTests {
  private let demo = URL(string: "http://127.0.0.1:6767")
  private let linked = URL(string: "https://linked.example.com")
  private let preferred = URL(string: "https://preferred.example.com")

  /// A launch with no link opens on the person's default server, or the connect screen.
  @Test func aNewWindowOpensOnTheDesktopsDefaultServer() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let desktop = scratch.desktop
    #expect(OmnigentMacApp.newWindowServerURL(demo: nil, desktop: desktop) == nil)
    desktop.preferences.defaultServerURL = preferred
    #expect(OmnigentMacApp.newWindowServerURL(demo: nil, desktop: desktop) == preferred)
    #expect(OmnigentMacApp.newWindowServerURL(demo: demo, desktop: desktop) == demo)
  }

  /// Only a person's real launch brings back the windows it left.
  @Test func aRealLaunchRestoresItsWindows() {
    let ignores = OmnigentMacAppDelegate.ignoresSavedWindows
    #expect(!ignores(false, false))
    #expect(ignores(true, false))
    #expect(ignores(false, true))
    #expect(ignores(true, true))
  }

  @Test func aNewWindowPrefersTheDemoThenALinkThenTheDefault() {
    let choose = OmnigentMacApp.newWindowServerURL(demo:linked:preferred:)
    #expect(choose(demo, linked, preferred) == demo)
    #expect(choose(nil, linked, preferred) == linked)
    #expect(choose(nil, nil, preferred) == preferred)
  }

  /// First run: nothing chosen yet, so the window opens on the connect screen.
  @Test func aFirstRunOpensOnTheConnectScreen() {
    #expect(OmnigentMacApp.newWindowServerURL(demo: nil, linked: nil, preferred: nil) == nil)
  }

  @Test func theHelpMenuHasADestination() {
    #expect(OmnigentMacApp.helpURL?.host() == "github.com")
  }

  @Test func theDemoIsOffUnlessAsked() {
    #expect(!OmnigentMacAppDelegate.isDemo)
    #expect(OmnigentMacAppDelegate.demoServerURL == nil)
  }

  struct ResumeCase: Sendable {
    let url: String?
    var isDemo = false
    let isRunning: Bool
    /// Another server answers at the window's loopback address.
    var isServed = false
    let resumes: Bool
  }

  @Test(arguments: [
    ResumeCase(url: nil, isRunning: false, resumes: true),
    ResumeCase(url: nil, isRunning: true, resumes: true),
    ResumeCase(url: "http://127.0.0.1:6767", isRunning: false, resumes: true),
    ResumeCase(url: "http://localhost:6767", isRunning: false, resumes: true),
    ResumeCase(url: "http://127.0.0.1:6767", isRunning: true, resumes: false),
    ResumeCase(url: "https://omnigent.example.com", isRunning: false, resumes: false),
    ResumeCase(url: "https://omnigent.example.com", isRunning: true, resumes: false),
    // Terminal's or a test's server holds the address: the window stays on it.
    ResumeCase(url: "http://127.0.0.1:6767", isRunning: false, isServed: true, resumes: false),
    // The demo's server is offline; no window of it starts a real one.
    ResumeCase(url: "http://127.0.0.1:6767", isDemo: true, isRunning: false, resumes: false),
    ResumeCase(url: nil, isDemo: true, isRunning: false, resumes: false),
  ])
  func aWindowOnThisMacsStoppedServerGoesBackToIt(_ item: ResumeCase) {
    var asked: [String] = []
    let resumes = ServerWindowRoot.resumesLocalServer(
      boundTo: item.url.flatMap(URL.init(string:)), isDemo: item.isDemo,
      localServerIsRunning: item.isRunning,
      isServed: { url in
        asked.append(url.absoluteString)
        return item.isServed
      })
    #expect(resumes == item.resumes)
    // Only a window on this Mac's stopped address has its port checked.
    let checksPort = !item.isDemo && !item.isRunning && item.url?.hasSuffix(":6767") == true
    #expect(asked == (checksPort ? [item.url ?? ""] : []))
  }
}

/// Chaos and debug tools must never run in a launch that didn't ask for them.
@MainActor
struct DebugHooksTests {
  @Test func aDebugBuildShowsTheDebugMenuAndAReleaseBuildOnlyWhenAsked() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    #expect(DebugCommands.isEnabled(isDebugBuild: true, defaults: scratch.defaults))
    #expect(!DebugCommands.isEnabled(isDebugBuild: false, defaults: scratch.defaults))
    scratch.defaults.set(true, forKey: "OmnigentDebugMenu")
    #expect(DebugCommands.isEnabled(isDebugBuild: false, defaults: scratch.defaults))
  }

  #if DEBUG
    @Test func thisDebugBuildShowsTheDebugMenu() {
      #expect(DebugCommands.isEnabled)
    }

    /// `startIfRequested` is what launch calls. Unasked, it leaves every diagnostic unset.
    @Test func chaosStaysOffUnlessTheLaunchAsks() throws {
      let scratch = try TestScratch()
      defer { scratch.remove() }
      for key in ["OmnigentChaos", "OmnigentChaosScript", "OmnigentChaosLog"] {
        #expect(UserDefaults.standard.object(forKey: key) == nil, "\(key) is set")
      }
      let router = scratch.desktop.router
      #expect(!ChaosScript.startIfRequested(router: router, serverURL: { nil }))
      ChaosDriver.startIfRequested(router: router, serverURL: { nil })
      // Not `HangTrace.isEnabled`: the hang watch's own tests leave it on for this process.
      #expect(LoopProbe.sink == nil)
    }

    @Test func theUndoGuardIsOnUnlessAChaosRunTurnsItOff() {
      #expect(!UserDefaults.standard.bool(forKey: "OmnigentNoTextUndoGuard"))
    }
  #endif
}

@MainActor
struct AppEditionTests {
  @Test func eachEditionHasANameAndItsLocalServerCapability() {
    #expect(AppEdition.developerID.displayName == "Developer ID")
    #expect(AppEdition.appStore.displayName == "Mac App Store")
    #expect(AppEdition.developerID.localServerCapability == .available)
    #expect(AppEdition.appStore.localServerCapability == .unavailable(.appSandbox))
  }
}
