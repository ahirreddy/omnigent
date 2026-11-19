import Testing

@testable import OmnigentUIComponents

struct ProjectRepositoryDraftTests {
  @Test("A new project starts from a repository on a sandbox always, on a host by choice")
  func projectSource() {
    let choices = [
      ProjectRunChoice(id: "mac", title: "Mac"),
      ProjectRunChoice(id: "__sandbox__:modal", title: "Modal Sandbox", isSandbox: true),
    ]
    var draft = ProjectRepositoryDraft()
    draft.targetID = "mac"
    #expect(!draft.startsFromRepository(choices))
    draft.fromRepository = true
    #expect(draft.startsFromRepository(choices))
    draft.fromRepository = false
    draft.targetID = "__sandbox__:modal"
    #expect(draft.startsFromRepository(choices))
  }
}
