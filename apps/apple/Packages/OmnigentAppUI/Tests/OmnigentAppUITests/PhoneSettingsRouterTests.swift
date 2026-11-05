import OmnigentUIComponents
import SwiftUI
import Testing

@testable import OmnigentAppUI

@Suite("iPhone and iPad Settings routing")
@MainActor
struct PhoneSettingsRouterTests {
  private let scene = "http://127.0.0.1:6767"

  @Test("tabs push their page on the scene's server; General and Servers open the root")
  func tabs() {
    let cases: [(String, PhoneSettingsRoute.Page?)] = [
      (SettingsNavigator.appearanceTab, .app(.appearance)),
      (SettingsNavigator.notificationsTab, .app(.notifications)),
      (SettingsNavigator.terminalTab, .app(.terminal)),
      (SettingsNavigator.generalTab, nil),
      (SettingsNavigator.serversTab, nil),
      ("Phone", nil),
    ]
    for (tab, page) in cases {
      let route = PhoneSettingsRoute(.tab(tab), sceneServer: scene)
      #expect(route.serverURL == scene && route.page == page, "\(tab)")
    }
  }

  @Test("a server destination pushes its pane on its server, else the scene's")
  func serverPanes() {
    let other = PhoneSettingsRoute(
      .server(url: "https://b.example.com", pane: .importSessions), sceneServer: scene)
    #expect(other.serverURL == "https://b.example.com" && other.page == .server(.importSessions))
    let current = PhoneSettingsRoute(.server(url: nil, pane: nil), sceneServer: scene)
    #expect(current.serverURL == scene && current.page == nil)
    let signedOut = PhoneSettingsRoute(.server(url: nil, pane: .git), sceneServer: nil)
    #expect(signedOut.serverURL == nil && signedOut.page == .server(.git))
  }

  @Test("each tab id maps to its page")
  func pagesFromTabs() {
    for page in PhoneSettingsPage.allCases {
      #expect(PhoneSettingsPage(tab: page.title) == page)
    }
    #expect(PhoneSettingsPage(tab: SettingsNavigator.serversTab) == nil)
  }

  @Test("a debug launch names a page or a pane")
  func launchNames() {
    #expect(PhoneSettingsRoute.Page(launchName: "general") == .app(.general))
    #expect(PhoneSettingsRoute.Page(launchName: "importSessions") == .server(.importSessions))
    #expect(PhoneSettingsRoute.Page(launchName: "root") == nil)
  }

  @Test("opening presents the screen, replaces the path and asks for the server")
  func open() throws {
    let router = PhoneSettingsRouter()
    router.sceneServer = { [scene] in scene }
    let openAt = try #require(router.openAt)
    openAt(.server(url: nil, pane: .archived))
    // The page waits for the root list to show, then pushes once.
    #expect(router.isPresented && router.path.isEmpty)
    router.screenAppeared()
    #expect(router.path.count == 1)
    router.screenAppeared()
    #expect(router.path.count == 1)
    let request = router.navigator.takeServerRequest()
    #expect(request?.url == scene && request?.pane == nil)

    // While presented, a destination replaces the path at once.
    router.appearance.open?()
    #expect(router.isPresented && router.path.count == 1)
    router.screen.open?()
    #expect(router.path.isEmpty)
    router.notifications.open?()
    #expect(router.path.count == 1)
    #expect(router.navigator.takeServerRequest()?.url == scene)
  }

  @Test("the environment actions are equal only for the same scene")
  func stableActions() {
    let router = PhoneSettingsRouter()
    let first = OpenSettingsScreenAction(presenter: router.screen)
    let later = OpenSettingsScreenAction(presenter: router.screen)
    #expect(first == later)
    #expect(
      OpenAppearanceSettingsAction(presenter: router.appearance)
        != OpenAppearanceSettingsAction(presenter: PhoneSettingsRouter().appearance))
  }
}
