import OmnigentDeepLinks
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@Suite("Page and settings links")
struct DeepLinkDestinationsTests {
  @Test("each page link selects its sidebar destination")
  func pages() {
    #expect(DeepLinkDestinations.selection(for: .newSession) == .newSession)
    #expect(DeepLinkDestinations.selection(for: .usage) == .usage)
    #expect(DeepLinkDestinations.selection(for: .automations) == .automations)
    #expect(DeepLinkDestinations.selection(for: .inbox) == .inbox)
    #expect(DeepLinkDestinations.selection(for: .canvas) == .canvas)
  }

  @Test("web settings sections open the app's tabs or the server's panes")
  func settings() {
    let server = "http://127.0.0.1:6767"
    let settings = { (section: String?) in
      DeepLinkDestinations.settings(section: section, server: server)
    }
    #expect(settings(nil) == .tab(SettingsNavigator.generalTab))
    #expect(settings("general") == .tab(SettingsNavigator.generalTab))
    #expect(settings("appearance") == .tab(SettingsNavigator.appearanceTab))
    #expect(settings("mcp") == .server(url: server, pane: .mcp))
    #expect(settings("custom-agents") == .server(url: server, pane: .customAgents))
    #expect(settings("import") == .server(url: server, pane: .importSessions))
    #expect(settings("archived") == .server(url: server, pane: .archived))
    #expect(settings("shortcuts") == .tab(SettingsNavigator.generalTab))
  }
}
