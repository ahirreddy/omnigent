import Foundation
import Testing

@testable import OmnigentUIComponents

/// Actions and small values views read: what they were given is what they use.
@Suite("View state: actions and small values")
struct ViewStateActionTests {
  @Test("A share role names itself")
  func shareRoles() {
    #expect(ShareGrant.Role.read.title == "Read")
    #expect(ShareGrant.Role.edit.title == "Edit")
  }

  @Test("Share actions hold what they were given, and only that")
  @MainActor
  func shareActions() {
    var removed: [String] = []
    let actions = ShareActions(removeGrant: { removed.append($0.id) })
    actions.removeGrant?(ShareGrant(id: "g", principal: "p", role: .read))
    #expect(removed == ["g"])
    #expect(actions.addGrant == nil)
    #expect(actions.setRole == nil)
  }

  @Test("Fork actions built from the three answers pass those three on")
  @MainActor
  func forkActions() {
    var forked: [String] = []
    let actions = ForkActions(
      fork: { agent, directory, start in forked.append("\(agent) \(directory) \(start)") },
      cancel: {})
    actions.forkWith(ForkChoices(agentID: "a", directory: "/d", start: true))
    #expect(forked == ["a /d true"])
  }

  @Test("A conversation's rows split into the transcript and the activity drawer")
  func conversationRows() {
    let state = ConversationViewState(
      header: SessionHeader(id: "s", title: "S"),
      rows: [
        Row(id: "said", role: .assistant), Row(id: "lifecycle", role: .tool, isActivityOnly: true),
      ])
    #expect(state.transcriptRows.map(\.id) == ["said"])
    #expect(state.lifecycleRows.map(\.id) == ["lifecycle"])
  }

  @Test("Choosing a model keeps the effort it supports, or one that reports no efforts")
  func effortKept() {
    var configuration = ComposerConfiguration(
      modelOptions: [
        ModelOption(id: "some", supportedReasoningEfforts: ["low", "high"]),
        ModelOption(id: "none"),
      ], selectedEffort: "high")
    #expect(configuration.effortKept(selecting: "some") == "high")
    #expect(configuration.effortKept(selecting: "none") == "high")
    configuration.selectedEffort = "max"
    #expect(configuration.effortKept(selecting: "some") == nil)
    #expect(configuration.effortKept(selecting: "none") == "max")
    configuration.selectedEffort = nil
    #expect(configuration.effortKept(selecting: "some") == nil)
  }

  @Test("An account is an ordinary one unless it says otherwise")
  func account() {
    let account = ServerAccountState(userID: "me")
    #expect(account.userID == "me")
    #expect(!account.isAdmin)
    #expect(!account.canChangePassword)
  }

  @Test("The palette's actions run the destination they're given")
  @MainActor
  func paletteActions() {
    var performed: [PaletteTarget] = []
    let actions = PaletteActions(perform: { performed.append($0) })
    actions.perform(.inbox)
    #expect(performed == [.inbox])
    #expect(actions.search == nil)
  }

  @Test("An invite link keeps its address, with no expiry unless told one")
  func inviteLink() {
    #expect(MemberInviteLink(url: "https://x").url == "https://x")
    #expect(MemberInviteLink(url: "https://x").expiresAt == nil)
  }

  @Test("The live transcript reads its rows when asked")
  @MainActor
  func liveRows() {
    let rows = LiveTranscriptRows { ([Row(id: "a", role: .user)], 7) }
    #expect(rows.read().rows.map(\.id) == ["a"])
    #expect(rows.read().revision == 7)
  }

  @Test("A chosen repository is identified by its address")
  func repositoryIdentity() {
    #expect(SandboxRepoChoice(url: "https://x").id == "https://x")
  }
}
