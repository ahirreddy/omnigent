import OmnigentCoreFFI
import Testing

@testable import OmnigentAppUI

/// When a conversation's messages carry their author's avatar: only in a session shared with
/// other people, as the web decides it.
@Suite("Author badges")
struct ConversationSharingTests {
  private func server(_ user: String) -> ConnectedServer {
    ConnectedServer(
      baseUrl: "https://omnigent.example.com", serverName: nil, userId: user, accountId: user,
      mode: .oidc)
  }

  private func grant(_ user: String, level: UInt8 = 1) -> SessionGrant {
    SessionGrant(userId: user, level: level, isOwner: level == 4)
  }

  @Test("the viewer is the signed-in user, never the single-user local one")
  func viewer() {
    #expect(ConversationAdapter.viewer(server("ada@example.com")) == "ada@example.com")
    #expect(ConversationAdapter.viewer(server("local")) == nil)
    #expect(ConversationAdapter.viewer(server("")) == nil)
    #expect(ConversationAdapter.viewer(nil) == nil)
  }

  @Test("someone else's session is shared; the viewer's own is shared once they grant anyone")
  func shared() {
    let ada = "ada@example.com"
    #expect(ConversationAdapter.isShared(owner: "bob@example.com", viewer: ada, grants: []))
    #expect(!ConversationAdapter.isShared(owner: ada, viewer: ada, grants: []))
    #expect(!ConversationAdapter.isShared(owner: ada, viewer: ada, grants: [grant(ada, level: 4)]))
    #expect(
      ConversationAdapter.isShared(
        owner: ada, viewer: ada, grants: [grant(ada, level: 4), grant("bob@example.com")]))
    #expect(
      ConversationAdapter.isShared(owner: nil, viewer: ada, grants: [grant(publicGrantee())]))
    #expect(!ConversationAdapter.isShared(owner: "bob@example.com", viewer: nil, grants: []))
  }
}
