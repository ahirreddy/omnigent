import Foundation
import Testing

@testable import OmnigentDeepLinks

@Suite("Web links to the connected server")
struct WebLinkRouteTests {
  private func route(_ link: String, server: String = "http://127.0.0.1:6767") -> DeepLinkRoute? {
    guard let url = URL(string: link), let server = URL(string: server) else { return nil }
    return DeepLinkRoute(webURL: url, server: server)
  }

  @Test("routes the web app's session, message, page and settings paths on the same origin")
  func sameOrigin() {
    #expect(route("http://127.0.0.1:6767/c/conv_a") == .conversation(sessionID: "conv_a"))
    #expect(
      route("http://127.0.0.1:6767/c/conv_a?message=msg_1#top")
        == .message(sessionID: "conv_a", messageID: "msg_1"))
    #expect(route("http://127.0.0.1:6767/usage") == .page(.usage))
    #expect(route("http://127.0.0.1:6767/settings/mcp") == .settings(section: "mcp"))
    #expect(route("http://127.0.0.1:6767/") == .home)
    #expect(route("HTTP://127.0.0.1:6767/c/conv_a") == .conversation(sessionID: "conv_a"))
  }

  @Test("leaves other origins, API paths and invites to the browser")
  func otherLinks() {
    #expect(route("http://127.0.0.1:6768/c/conv_a") == nil)
    #expect(route("https://127.0.0.1:6767/c/conv_a") == nil)
    #expect(route("http://example.com/c/conv_a") == nil)
    #expect(route("http://127.0.0.1:6767/v1/sessions/conv_a") == nil)
    #expect(route("http://127.0.0.1:6767/register?invite=abc") == nil)
    #expect(route("mailto:someone@example.com") == nil)
  }

  @Test("strips the server's mount and ignores paths outside it")
  func mount() {
    let server = "https://dbc.example.com/omnigent/"
    #expect(
      route("https://dbc.example.com/omnigent/c/conv_a", server: server)
        == .conversation(sessionID: "conv_a"))
    #expect(route("https://dbc.example.com/omnigent", server: server) == .home)
    #expect(route("https://dbc.example.com/c/conv_a", server: server) == nil)
    #expect(route("https://dbc.example.com/omnigentx/c/conv_a", server: server) == nil)
  }
}
