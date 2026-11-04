import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import OmnigentWorkspaceUI
import Testing

@testable import OmnigentAppUI

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func pullRequest(
  number: UInt64, title: String? = "Fix login", relationship: String = "created",
  status: OmnigentCoreFFI.PullRequestStatus = .open, checkedAt: Double? = nil
) -> SessionPullRequest {
  SessionPullRequest(
    url: "https://github.com/o/r/pull/\(number)", host: "github.com", repository: "o/r",
    number: number, title: title, relationship: relationship, providerName: "GitHub",
    status: status, stateCheckedAt: checkedAt)
}

@MainActor
struct PullRequestAdapterTests {
  @Test func theTabWaitsForFeaturesAndSaysWhenTheServerStoresNone() {
    #expect(
      PullRequestAdapter.state(features: nil, featuresError: nil, pullRequests: .idle) == .loading)
    let unsupported = PanelFeatures(contentSearch: true, pullRequests: false)
    #expect(
      PullRequestAdapter.state(features: unsupported, featuresError: nil, pullRequests: .idle)
        == .unsupported)
  }

  @Test func rowsCarryStatusRelationshipAndAStaleCheck() {
    let features = PanelFeatures(contentSearch: false, pullRequests: true)
    let list = SessionPullRequests(
      pullRequests: [
        pullRequest(number: 1, status: .draft, checkedAt: now.timeIntervalSince1970 - 60),
        pullRequest(
          number: 2, title: nil, relationship: "inferred", status: .merged,
          checkedAt: now.timeIntervalSince1970 - 7_200),
      ],
      synced: true)
    guard
      case .loaded(let rows, let synced) = PullRequestAdapter.state(
        features: features, featuresError: nil, pullRequests: .loaded(list), now: now)
    else {
      Issue.record("expected rows")
      return
    }
    #expect(synced)
    #expect(rows.map(\.status) == [.draft, .merged])
    #expect(rows[0].detail == "Created in this session", "a fresh state needs no age")
    #expect(rows[1].title == "Pull request #2")
    #expect(rows[1].detail?.hasPrefix("From the session's branch \u{00B7} Checked ") == true)
  }
}

@MainActor
struct WorkspacePanelSlotsTests {
  @Test func fileAndDiffTabsAreNamedForTheFile() {
    let file = WorkspacePanelSlots.tab(.file(path: "src/main.rs", line: 3))
    #expect(file.id == "file:src/main.rs")
    #expect(file.title == "main.rs")
    #expect(file.detail == "src/main.rs")
    let diff = WorkspacePanelSlots.tab(.diff(path: "src/main.rs"))
    #expect(diff.id == "diff:src/main.rs")
    #expect(diff.systemImage == "plus.forwardslash.minus")
  }

  @Test func openedFilesBecomeTabsAndShowingAPanelKeepsThem() async {
    let workspace = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
    await workspace.open(.file(path: "README.md", line: nil))
    await workspace.open(.diff(path: "src/lib.rs"))
    let documents = WorkspacePanelSlots.documents(workspace, actions: .none)
    #expect(documents.tabs.map(\.id) == ["file:README.md", "diff:src/lib.rs"])
    #expect(documents.selected == "diff:src/lib.rs")
    documents.showPanel()
    #expect(workspace.document == nil)
    #expect(workspace.openDocuments.count == 2)
  }
}
