import Foundation
import OmnigentAppBrowser
import OmnigentAppUI
import OmnigentAuthUI
import OmnigentDesktop
import OmnigentStores
import OmnigentUIComponents
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// The services every window shares.
@MainActor
struct AppServicesTests {
  private final class Permission: NotificationAuthorizing {
    var authorization: DesktopNotificationCenter.Authorization
    var requests = 0
    var fails = false

    init(_ authorization: DesktopNotificationCenter.Authorization) {
      self.authorization = authorization
    }

    func refreshAuthorization() async throws(DesktopNotificationError) {
      await Task.yield()
      if fails { throw .unavailable }
    }

    func requestAuthorization() async throws(DesktopNotificationError) -> Bool {
      await Task.yield()
      requests += 1
      return true
    }
  }

  private let serverURL = URL(string: "https://omnigent.example.com")

  @Test func theFirstConnectionRecordsTheServerAndAsksForNotificationsOnce() async throws {
    let permission = Permission(.notDetermined)
    let scratch = try TestScratch(notificationPermission: permission)
    defer { scratch.remove() }
    let url = try #require(serverURL)
    await scratch.services.didConnect(to: url)
    await scratch.services.didConnect(to: url)
    #expect(scratch.services.recentServers.urls == [url])
    #expect(permission.requests == 1)
  }

  @Test(arguments: [
    DesktopNotificationCenter.Authorization.authorized, .denied, .provisional, .unknown,
  ])
  func aDecidedPermissionIsNotAskedAgain(
    authorization: DesktopNotificationCenter.Authorization
  ) async throws {
    let permission = Permission(authorization)
    let scratch = try TestScratch(notificationPermission: permission)
    defer { scratch.remove() }
    await scratch.services.didConnect(to: try #require(serverURL))
    #expect(permission.requests == 0)
  }

  @Test func aPermissionFailureIsReportedAndTheServerStillRecorded() async throws {
    let permission = Permission(.notDetermined)
    permission.fails = true
    let scratch = try TestScratch(notificationPermission: permission)
    defer { scratch.remove() }
    var issues: [DesktopIssue] = []
    scratch.desktop.onIssue = { issues.append($0) }
    let url = try #require(serverURL)
    await scratch.services.didConnect(to: url)
    #expect(scratch.services.recentServers.urls == [url])
    #expect(issues.count == 1)
    guard case .notificationFailed = issues.first else {
      Issue.record("Wrong issue: \(issues)")
      return
    }
  }

  @Test func quittingFlushesDraftsAndKeepsClosingWindowsTabs() throws {
    var flushes = 0
    let scratch = try TestScratch(flushDrafts: { flushes += 1 })
    defer { scratch.remove() }
    let services = scratch.services
    let window = UUID()
    let tabs = SessionTabGroups()
    let page = services.browserTabs.makePage(url: serverURL)
    tabs.show(.session("session"))
    tabs.open(.browser(browserID: page.id))
    services.browserTabs.attach(window: window, tabs: tabs)

    #expect(!services.isTerminating)
    services.willTerminate()
    #expect(services.isTerminating)
    #expect(flushes == 1)

    services.windowClosed(window)
    #expect(services.browserTabs.status(of: page.id) != nil, "quitting closed a saved page")
  }

  @Test func closingAWindowClosesItsBrowserPages() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let services = scratch.services
    let window = UUID()
    let tabs = SessionTabGroups()
    let page = services.browserTabs.makePage(url: serverURL)
    tabs.show(.session("session"))
    tabs.open(.browser(browserID: page.id))
    services.browserTabs.attach(window: window, tabs: tabs)

    services.windowClosed(window)
    #expect(services.browserTabs.status(of: page.id) == nil)
  }

  @Test func bindingLetsDeepLinksTrustKnownServersAndRememberNewOnes() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let url = try #require(serverURL)
    scratch.services.bind()
    let router = scratch.desktop.router
    #expect(router.knownServers().isEmpty)
    router.rememberServer(url)
    #expect(scratch.services.recentServers.urls == [url])
    #expect(router.knownServers() == [url])
  }

  /// Every kind of issue reaches the log without trapping, once bound.
  @Test func boundIssuesAreLogged() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    scratch.defaults.set(["not a url"], forKey: RecentServers.defaultsKey)
    let services = scratch.isolation.makeServices(desktop: scratch.desktop)
    #expect(services.recentServers.rejectedEntries == ["not a url"])
    services.bind()
    let origin = try ServerOrigin(url: try #require(serverURL))
    let issues: [DesktopIssue] = [
      .consentDeclined(origin), .awaitingWindowOpener(pending: 2), .routingFailed("no window"),
      .notificationFailed(.unavailable), .unrecognizedNotificationPayload(identifier: "id"),
      .supervision("denied"),
    ]
    for issue in issues { scratch.desktop.onIssue(issue) }
  }

  @Test func organizationServersComeFirstInTheDirectory() throws {
    let scratch = try TestScratch(managedByOwnSuite: true)
    defer { scratch.remove() }
    let recent = try #require(serverURL)
    scratch.services.recentServers.record(recent)
    scratch.defaults.set(["https://org.example.com"], forKey: ManagedPreferences.serverURLsKey)
    scratch.defaults.synchronize()

    let organization = scratch.services.organizationServers().map(\.host)
    #expect(organization == ["org.example.com"])
    #expect(scratch.services.knownServers().map(\.host) == [recent.host, "org.example.com"])
    let directory = scratch.services.serverDirectory()
    #expect(directory.managed.map(\.url).first?.contains("org.example.com") == true)
    #expect(!directory.serversAreForced)
    #expect(directory.recentServers == [recent.absoluteString])
  }

  @Test func invalidOrganizationServersAreIgnored() throws {
    let scratch = try TestScratch(managedByOwnSuite: true)
    defer { scratch.remove() }
    scratch.defaults.set(5, forKey: ManagedPreferences.serverURLsKey)
    scratch.defaults.synchronize()
    #expect(scratch.services.organizationServers().isEmpty)
    #expect(scratch.services.serverDirectory().managed.isEmpty)
  }

  @Test func pairingOffersRecentServersWithoutRepeats() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let url = try #require(serverURL)
    scratch.services.recentServers.record(url)
    scratch.services.recentServers.record(url)
    #expect(scratch.services.pairingServers().filter { $0 == url.absoluteString }.count == 1)
  }

  @Test func aDemoLaunchGetsTheOfflineServer() throws {
    let scratch = try TestScratch(launchArguments: ["-OmnigentDemo"])
    defer { scratch.remove() }
    #expect(scratch.services.makeServerSession().isDemo)
  }

  @Test func savedTabsLiveInTheChosenDirectory() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    #expect(scratch.services.tabPersistence != nil)
  }

  @Test func forgettingARecentServerRemovesItForGood() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let url = try #require(serverURL)
    let recents = RecentServers(defaults: scratch.defaults)
    recents.record(url)
    recents.forget(url)
    #expect(recents.urls.isEmpty)
    #expect(RecentServers(defaults: scratch.defaults).urls.isEmpty)
    recents.forget(url)
    #expect(recents.urls.isEmpty)
  }
}
