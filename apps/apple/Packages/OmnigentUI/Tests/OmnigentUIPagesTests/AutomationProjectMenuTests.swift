import SwiftUI
import Testing

@testable import OmnigentUIComponents

/// The editor's Project menu names the chosen project, one named to make, or none.
@MainActor
@Suite("Automation project menu")
struct AutomationProjectMenuTests {
  private let projects = [AutomationOption(id: "p1", name: "Release")]

  private func title(projectID: String = "", projectName: String? = nil) -> String {
    var draft = AutomationDraftState(name: "Nightly", agentID: "a1")
    draft.projectID = projectID
    draft.projectName = projectName
    return AutomationProjectMenu(draft: .constant(draft), projects: projects).title
  }

  @Test("A chosen project, a gone one, a name to make, and none")
  func titles() {
    #expect(title(projectID: "p1") == "Release")
    #expect(title(projectID: "gone") == "Project unavailable")
    #expect(title(projectName: "Omnigent Automation") == "Omnigent Automation")
    #expect(title() == "No project")
  }
}
