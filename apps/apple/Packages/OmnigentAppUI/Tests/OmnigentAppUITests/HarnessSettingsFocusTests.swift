import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The `/mcp` panel's Go to Settings opens the Harnesses pane on the session's host and harness,
/// as the web's `/settings/harnesses/<harness>?host=<host>` link.
@Suite("Harness settings focus")
@MainActor
struct HarnessSettingsFocusTests {
  @Test("a harness destination opens Harnesses and leaves the host and harness for the pane")
  func navigator() {
    let navigator = SettingsNavigator()
    let focus = HarnessSettingsFocus(harness: "claude-native", hostID: "host_a")
    navigator.show(.harness(url: "https://a.example.com", focus: focus))
    #expect(navigator.tab == SettingsNavigator.serversTab)
    let request = navigator.takeServerRequest()
    #expect(request?.url == "https://a.example.com" && request?.pane == .harnesses)
    let taken = navigator.takeHarnessFocus()
    #expect(taken?.harness == "claude-native" && taken?.hostID == "host_a")
    #expect(navigator.takeHarnessFocus() == nil, "the pane takes it once")
  }

  @Test("asking for the same host and harness again is a new request")
  func distinct() {
    let first = HarnessSettingsFocus(harness: "codex-native", hostID: nil)
    let again = HarnessSettingsFocus(harness: "codex-native", hostID: nil)
    #expect(first != again)
  }

  @Test("on iPhone and iPad a harness destination pushes Harnesses on its server")
  func phoneRoute() {
    let focus = HarnessSettingsFocus(harness: nil, hostID: "host_a")
    let route = PhoneSettingsRoute(.harness(url: nil, focus: focus), sceneServer: "https://s.test")
    #expect(route.serverURL == "https://s.test" && route.page == .server(.harnesses))
    let router = PhoneSettingsRouter()
    router.open(.harness(url: nil, focus: focus))
    #expect(router.navigator.takeHarnessFocus()?.hostID == "host_a")
  }
}
