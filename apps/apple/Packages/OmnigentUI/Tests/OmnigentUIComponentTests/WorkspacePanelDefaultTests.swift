import Testing

@testable import OmnigentUIComponents

@Suite("Right panel default")
struct WorkspacePanelDefaultTests {
  @Test("an open default shows the panel as a column, never as a sheet over the chat")
  func opensOnlyAsColumn() {
    #expect(WorkspacePanelDefault.open.showsPanel(isSheet: false))
    #expect(!WorkspacePanelDefault.open.showsPanel(isSheet: true))
    #expect(!WorkspacePanelDefault.collapsed.showsPanel(isSheet: false))
    #expect(!WorkspacePanelDefault.collapsed.showsPanel(isSheet: true))
  }
}
