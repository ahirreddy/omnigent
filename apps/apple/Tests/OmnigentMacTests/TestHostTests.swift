import AppKit
import OmnigentBrowser
import OmnigentDesktop
import Testing
import UserNotifications

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// A test run shares a bundle identifier with the user's copy of the app. These pin both sides:
/// a real launch keeps doing its work over the user's data, and a test host does none of it.
@MainActor
struct TestHostDetectionTests {
  @Test(arguments: ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"])
  func anyTestVariableWithXCTestLoadedIsAHost(key: String) {
    #expect(TestHost.isHosting(environment: [key: "/tmp/x"], hasXCTest: true))
  }

  @Test func aRealLaunchIsNotAHost() {
    #expect(!TestHost.isHosting(environment: [:], hasXCTest: false))
    #expect(!TestHost.isHosting(environment: ["HOME": "/Users/me"], hasXCTest: true))
  }

  @Test func anInheritedVariableWithoutXCTestIsNotAHost() {
    #expect(!TestHost.isHosting(environment: ["XCTestBundlePath": "/tmp/x"], hasXCTest: false))
  }

  @Test func thisProcessIsDetected() {
    #expect(OmnigentMacAppDelegate.isTestHost)
  }
}

@MainActor
struct TestHostLaunchWorkTests {
  private final class Calls {
    var names: [String] = []
  }

  private func work(_ calls: Calls) -> TestHost.LaunchWork {
    TestHost.LaunchWork(
      startLocalServer: { calls.names.append("server") },
      startChaos: { calls.names.append("chaos") },
      startUpdater: { calls.names.append("updater") })
  }

  @Test func aRealLaunchRunsAllItsWorkInOrder() {
    let calls = Calls()
    work(calls).run(isTestHost: false)
    #expect(calls.names == ["server", "chaos", "updater"])
  }

  @Test func aTestHostRunsNone() {
    let calls = Calls()
    work(calls).run(isTestHost: true)
    #expect(calls.names.isEmpty)
  }
}

@MainActor
struct TestHostIsolationTests {
  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "omnigent-isolation-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  @Test func refusesTheAppsOwnPreferences() {
    let root = temporaryRoot()
    #expect(throws: TestHost.IsolationError.defaultsUnavailable(suite: "ai.omnigent.mac")) {
      try TestHost.Isolation(
        suite: "ai.omnigent.mac", root: root, bundleIdentifier: "ai.omnigent.mac")
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test func refusesASuiteUserDefaultsRejects() {
    #expect(throws: TestHost.IsolationError.defaultsUnavailable(suite: "NSGlobalDomain")) {
      try TestHost.Isolation(suite: "NSGlobalDomain", root: temporaryRoot())
    }
  }

  @Test func refusesADirectoryItCannotCreate() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let file = scratch.isolation.root.appending(path: "a-file")
    try Data().write(to: file)
    do {
      _ = try TestHost.Isolation(
        suite: "\(scratch.suite).nested", root: file.appending(path: "below"))
      Issue.record("A root under a file should fail")
    } catch {
      guard case .directoryUnavailable(let path, _) = error else {
        Issue.record("Wrong failure: \(error)")
        return
      }
      #expect(path.hasSuffix("a-file/below"))
      #expect(error.description.contains(path))
    }
  }

  /// A method that isn't there fails the launch rather than leaving the user's preferences on.
  @Test func standardDefaultsThatCantBeReplacedFailTheHost() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    #expect(throws: TestHost.IsolationError.standardDefaultsNotReplaced) {
      try scratch.isolation.replaceStandardDefaults(
        selector: NSSelectorFromString("noSuchDefaults"))
    }
  }

  /// A test host's answer never asks the person.
  @Test func deniedNotificationsNeverGrant() async throws {
    let permission = TestHost.DeniedNotifications()
    try await permission.refreshAuthorization()
    #expect(permission.authorization == .denied)
    #expect(try await !permission.requestAuthorization())
  }

  @Test func errorsSayWhatFailed() {
    #expect(
      TestHost.IsolationError.defaultsUnavailable(suite: "a.suite").description.contains("a.suite"))
    #expect(TestHost.IsolationError.standardDefaultsNotReplaced.description.contains("standard"))
    #expect(
      TestHost.IsolationError.notificationsNotReplaced(method: "add").description.contains("add"))
  }

  @Test func startsFromEmptyPreferences() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    scratch.defaults.set("left over", forKey: "earlier")
    let again = try TestHost.Isolation(suite: scratch.suite, root: scratch.isolation.root)
    #expect(again.defaults.string(forKey: "earlier") == nil)
  }

  @Test func desktopCannotReachTheUsersServerOrPreferences() async throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let manager = scratch.desktop.localServer
    #expect(!manager.capability.isAvailable)
    #expect(manager.dataDirectory.path.hasPrefix(scratch.isolation.root.path))
    #expect(!scratch.desktop.localServerPreferences.showsMenuBarExtra)
    #expect(UserDefaults.standard != scratch.defaults)

    let before = manager.server
    await manager.launch()
    #expect(manager.server == before)
    #expect(manager.server.endpoint == nil)
  }

  @Test func servicesKeepNothingInTheUsersFiles() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let services = scratch.services
    let serverURL = try #require(URL(string: "https://omnigent.example.com"))
    services.recentServers.record(serverURL)
    #expect(
      UserDefaults.standard.stringArray(forKey: RecentServers.defaultsKey)?.contains(
        serverURL.absoluteString) != true)
    #expect(
      scratch.defaults.stringArray(forKey: RecentServers.defaultsKey) == [serverURL.absoluteString])
    #expect(services.browser.directory == scratch.isolation.browserDirectory)
    #expect(
      scratch.defaults.string(forKey: AppServices.tabsDirectoryKey)?.hasPrefix(
        scratch.isolation.root.path) == true)
  }
}

@MainActor
struct LaunchDelegateTests {
  @Test func aRealLaunchsDesktopIsTheEditionsOverTheUsersData() {
    let desktop = OmnigentMacAppDelegate.makeDesktop(isolation: nil)
    let manager = desktop.localServer
    #expect(manager.capability == AppEdition.current.localServerCapability)
    let temporary = FileManager.default.temporaryDirectory.path
    #expect(!manager.dataDirectory.path.hasPrefix(temporary))
  }

  /// Code and frameworks that use `.standard` directly get the private preferences too.
  @Test func standardDefaultsAreNotTheUsers() throws {
    let bundleID = try #require(Bundle.main.bundleIdentifier)
    let key = "OmnigentHostedProbe.\(UUID().uuidString)"
    UserDefaults.standard.set("written", forKey: key)
    defer { UserDefaults.standard.removeObject(forKey: key) }
    #expect(UserDefaults.standard.string(forKey: key) == "written")
    #expect(CFPreferencesCopyAppValue(key as CFString, bundleID as CFString) == nil)
  }

  /// The center is the user's too, through the bundle identifier: nothing here may show, ask for
  /// permission or change what they have.
  @Test func nothingReachesTheUsersNotifications() async throws {
    let center = UNUserNotificationCenter.current()
    let before = TestHostNotifications.suppressedCount
    let content = UNMutableNotificationContent()
    content.title = "A test run must not show this"
    try await center.add(
      UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    #expect(TestHostNotifications.suppressedCount == before + 1)
    #expect(try await center.requestAuthorization(options: [.alert]) == false)
    #expect(center.delegate == nil)
  }

  /// Failing closed: a method it can't replace stops the host instead of leaving the real one.
  @Test func aMissingNotificationMethodFailsTheHost() {
    let name = "omnigentNoSuchMethod:"
    #expect(throws: TestHost.IsolationError.notificationsNotReplaced(method: name)) {
      try TestHostNotifications.replace(name, with: 0)
    }
  }

  private func finishedTurn() throws -> DesktopNotificationEvent {
    let url = try #require(URL(string: "https://omnigent.example.com"))
    return DesktopNotificationEvent(
      kind: .turnFinished, origin: try ServerOrigin(url: url), serverURL: url, sessionID: "conv",
      title: "A test run must not show this", body: "Done.")
  }

  /// In the host, a post that passes the policy still stops at the center's replaced method.
  @Test func aDeliveredPostStopsBeforeTheSystem() async throws {
    let center = DesktopNotificationCenter()
    // Active and viewing nothing: delivered, with no Dock request.
    center.contextProvider = {
      NotificationContext(appIsActive: true, viewing: nil, activeServerCount: 1)
    }
    let before = TestHostNotifications.suppressedCount
    guard case .deliver = try await center.post(try finishedTurn()) else {
      Issue.record("The policy should deliver this")
      return
    }
    #expect(TestHostNotifications.suppressedCount == before + 1)
  }

  /// The test host's own desktop doesn't even get that far.
  @Test func theHostsPolicySuppressesEveryKind() async throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let before = TestHostNotifications.suppressedCount
    let decision = try await scratch.desktop.notifications.post(try finishedTurn())
    guard case .suppress = decision else {
      Issue.record("Expected suppression, got \(decision)")
      return
    }
    #expect(TestHostNotifications.suppressedCount == before)
  }

  /// The real launch's side: no isolation, and a policy that delivers. Posting itself can't run
  /// here, as this process has the center replaced; a real post is checked in the VM.
  @Test func aRealLaunchKeepsItsNotifications() throws {
    #expect(OmnigentMacAppDelegate.isolationForLaunch(isTestHost: false) == nil)
    let desktop = OmnigentMacAppDelegate.makeDesktop(isolation: nil)
    let decision = NotificationPolicy.decide(
      try finishedTurn(),
      context: NotificationContext(appIsActive: false, viewing: nil, activeServerCount: 1),
      preferences: desktop.notifications.preferencesProvider())
    guard case .deliver = decision else {
      Issue.record("A real launch should deliver, got \(decision)")
      return
    }
    var installs = 0
    TestHost.LaunchWork.takeNotificationTaps(isTestHost: false) { installs += 1 }
    #expect(installs == 1)
    TestHost.LaunchWork.takeNotificationTaps(isTestHost: true) { installs += 1 }
    #expect(installs == 1)
  }

  /// A window's saved frame, which AppKit writes itself, stays out of the user's preferences:
  /// otherwise an offscreen test window would become where the user's next window opens.
  @Test func aSavedWindowFrameIsNotTheUsers() throws {
    let bundleID = try #require(Bundle.main.bundleIdentifier)
    let name = "OmnigentHostedProbe.\(UUID().uuidString)"
    let key = "NSWindow Frame \(name)" as CFString
    let window = NSWindow(
      contentRect: CGRect(x: -20_000, y: -20_000, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    #expect(window.setFrameAutosaveName(name))
    window.saveFrame(usingName: name)
    defer {
      NSWindow.removeFrame(usingName: name)
      CFPreferencesSetAppValue(key, nil, bundleID as CFString)
      CFPreferencesAppSynchronize(bundleID as CFString)
    }
    #expect(CFPreferencesCopyAppValue(key, bundleID as CFString) == nil)
  }

  /// A second delegate in the host: what the launch path gives, from the same detection.
  @Test func aHostedDelegateFinishesLaunchingWithoutTouchingAnything() {
    let delegate = OmnigentMacAppDelegate()
    let isolation = delegate.testHostIsolation
    #expect(isolation != nil)
    #expect(!delegate.desktop.localServer.capability.isAvailable)
    #expect(delegate.services.browser.directory == isolation?.browserDirectory)

    let before = delegate.desktop.localServer.server
    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification))
    #expect(delegate.desktop.localServer.server == before)
    #expect(delegate.desktop.localServer.cli == .notChecked)
  }
}
