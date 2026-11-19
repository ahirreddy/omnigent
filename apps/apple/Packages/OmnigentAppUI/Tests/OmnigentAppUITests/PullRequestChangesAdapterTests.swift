import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentWorkspaceUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

private let prURL = "https://github.com/o/r/pull/7"
private let github = "/v1/sessions/conv/resources/github"

/// The Changes tab's state from the store, with the web Changes tab's rules and wording.
@MainActor
@Suite("Pull request changes adapter")
struct PullRequestChangesAdapterTests {
  private func panel(commits: Bool = false) async throws -> SessionPanelStore {
    let info = #"""
      {"object":"session.github.info","available":true,"provider":"github",
       "repo":{"name_with_owner":"o/r"},"auth":{"authenticated":true},
       "provider_display":{"display_name":"GitHub"},"selected_pr_url":"\#(prURL)",
       "capabilities":{"commit_history":\#(commits)},
       "pr":{"number":7,"title":"Fix","state":"OPEN","url":"\#(prURL)","head_sha":"head1",
             "base_sha":"base1","head_repository_url":"https://github.com/fork/r"}}
      """#
    let patch =
      "diff --git a/src/a.rs b/src/a.rs\n--- a/src/a.rs\n+++ b/src/a.rs\n@@ -1 +1 @@\n-fn old\n+fn new\n"
    let body = try JSONSerialization.data(withJSONObject: [
      "object": "session.github.pr_diff", "patch": patch, "head_sha": "head1",
      "base_sha": "base1",
    ])
    let diff = try #require(String(bytes: body, encoding: .utf8))
    let core = try await ConversationFixtures.core(routes: [
      "/v1/info": .json(#"{"single_user":true,"accounts_enabled":false}"#),
      github: .json(info),
      "\(github)/diff": .json(diff),
      "\(github)/changes": .json(
        #"{"object":"list","data":[{"path":"src/a.rs","status":"modified","lines_added":1,"lines_removed":1},{"path":"gone.rs","status":"deleted","lines_added":0,"lines_removed":3}],"has_more":true,"warning":"Cut","total_count":4,"head_sha":"head1","base_sha":"base1"}"#
      ),
    ])
    let panel = SessionPanelStore(sessionID: "conv", core: core)
    await panel.showPullRequest(prURL)
    return panel
  }

  @Test("The tab lists the files, says the list is incomplete, and shows their diffs")
  func state() async throws {
    let panel = try await panel()
    let state = PullRequestChangesAdapter.state(panel, canEdit: true)
    #expect(state.treeFiles.map(\.path) == ["src/a.rs", "gone.rs"])
    #expect(state.listingNotice == "Cut")
    #expect(state.showsFileControls && !state.offersCommits)
    #expect(state.find?.isOpen == false)
    guard case .diff(let content) = state.body else {
      Issue.record("the files show")
      return
    }
    #expect(content.files.count == 2 && content.files[1].diff == nil)
    #expect(content.annotations.headers.keys.sorted() == ["gone.rs", "src/a.rs"])
  }

  @Test("Find says where it is and what the patch covers; filters say what they hide")
  func findAndFilters() async throws {
    let panel = try await panel()
    panel.openFind()
    panel.setFindQuery("fn")
    var state = PullRequestChangesAdapter.state(panel, canEdit: true)
    #expect(state.find?.status == "1 of 2")
    #expect(state.coverageNote == "Search covers the fetched patch: 1 of 4 files, 1 without text")
    panel.setPathFilter("gone")
    state = PullRequestChangesAdapter.state(panel, canEdit: true)
    #expect(state.find?.hidden == "+2 in hidden files")
    panel.setPathFilter("nothing")
    state = PullRequestChangesAdapter.state(panel, canEdit: true)
    guard case .message(let text, _, let action) = state.body else {
      Issue.record("a filter that matches nothing says so")
      return
    }
    #expect(text == "No changed files match \"nothing\"" && action?.title == "Clear filter")
  }

  private typealias Links = PullRequestChangesAdapter.FileLinks

  @Test("A file opens at the listed head, a deleted one at the base under its old name")
  func fileLinks() {
    let modified = StackedDiffFile(path: "src/a b.rs", kind: .modified)
    #expect(
      PullRequestChangesAdapter.fileURL(
        Links(
          provider: "github", headRepository: "https://github.com/fork/r",
          baseRepository: "https://github.com/o/r", head: "h1", base: "b1"),
        file: modified
      )?.absoluteString == "https://github.com/fork/r/blob/h1/src/a%20b.rs")
    let deleted = StackedDiffFile(path: "new.rs", previousPath: "old.rs", kind: .deleted)
    #expect(
      PullRequestChangesAdapter.fileURL(
        Links(
          provider: "gitlab", headRepository: nil, baseRepository: "https://gitlab.com/o/r",
          head: "h1", base: "b1"),
        file: deleted
      )?.absoluteString == "https://gitlab.com/o/r/-/blob/b1/old.rs")
    #expect(
      PullRequestChangesAdapter.fileURL(
        Links(
          provider: "azure_devops", headRepository: "https://dev.azure.com/o/p/_git/r",
          baseRepository: nil, head: "h1", base: nil),
        file: modified
      )?.absoluteString == "https://dev.azure.com/o/p/_git/r?path=/src/a%20b.rs&version=GCh1")
    #expect(
      PullRequestChangesAdapter.fileURL(
        Links(
          provider: "github", headRepository: "http://github.com/o/r", baseRepository: nil,
          head: "h1", base: nil),
        file: modified) == nil, "an insecure repository has no link")
    #expect(
      PullRequestChangesAdapter.repositoryURL(provider: "github", pullRequest: prURL)
        == "https://github.com/o/r")
    #expect(
      PullRequestChangesAdapter.repositoryURL(
        provider: "gitlab", pullRequest: "https://gitlab.com/g/r/-/merge_requests/3#note")
        == "https://gitlab.com/g/r")
    #expect(
      PullRequestChangesAdapter.repositoryURL(
        provider: "github", pullRequest: "https://github.com/o/r/pull/issues/7") == nil)
    #expect(PullRequestChangesAdapter.repositoryURL(provider: "other", pullRequest: prURL) == nil)
    #expect(
      PullRequestChangesAdapter.openUnavailable(provider: "GitHub", supported: true, source: nil)
        == "Source repository unavailable")
    #expect(
      PullRequestChangesAdapter.openUnavailable(
        provider: "Bitbucket", supported: false, source: nil)
        == "Opening files isn\u{2019}t supported for Bitbucket")
  }
}
