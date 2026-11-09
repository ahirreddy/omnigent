#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Records what the Pull Requests tab asks of the app, and answers links and comments.
  @MainActor
  final class PullRequestSpy {
    var calls: [String] = []
    var opened: [URL] = []
    var linkFinished: (@MainActor (Bool) -> Void)?
    var commentFinished: (@MainActor (Bool) -> Void)?

    var open: @MainActor (URL) -> Void { { [self] in opened.append($0) } }

    var actions: PullRequestPanelActions {
      var actions = PullRequestPanelActions()
      actions.select = { [self] in calls.append("select \($0)") }
      actions.showList = { [self] in calls.append("show list") }
      actions.link = { [self] address, finished in
        calls.append("link \(address)")
        linkFinished = finished
      }
      actions.unlink = { [self] in calls.append("unlink \($0)") }
      actions.refresh = { [self] in calls.append("refresh") }
      actions.loadLabels = { [self] in calls.append("load labels") }
      actions.setLabel = { [self] in calls.append("label \($0) \($1)") }
      actions.loadReviewers = { [self] in calls.append("load reviewers") }
      actions.setReviewer = { [self] in calls.append("reviewer \($0) \($1)") }
      actions.loadMergeMethods = { [self] in calls.append("load methods") }
      actions.merge = { [self] in calls.append("merge \($0)") }
      actions.disableAutoMerge = { [self] in calls.append("disable auto-merge") }
      actions.comment = { [self] text, finished in
        calls.append("comment \(text)")
        commentFinished = finished
      }
      actions.dismissError = { [self] in calls.append("dismiss error") }
      return actions
    }

    var extras: PullRequestPanelExtras {
      var extras = PullRequestPanelExtras()
      extras.actions = actions
      return extras
    }
  }

  enum PullRequestFixture {
    static let url = "https://example.test/acme/app/pull/7"

    static func summary(
      id: String = "7", number: Int = 7, status: PullRequestSummary.Status = .open,
      url: String = Self.url, detail: String? = nil
    ) -> PullRequestSummary {
      PullRequestSummary(
        id: id, number: number, title: "Add the sidebar", repo: "acme/app", url: url,
        status: status, detail: detail)
    }

    static var detail: PullRequestDetailViewState {
      PullRequestDetailViewState(
        url: url, title: "Add the sidebar", numberLabel: "#7", status: .ready,
        context: "acme/app: sidebar to main", providerName: "GitHub")
    }
  }

  extension OffscreenWindow {
    /// The first text field in the window.
    var firstTextField: NSTextField? {
      allViews.lazy.compactMap { $0 as? NSTextField }.first { $0.isEditable }
    }

    /// Clicks into a field, then types.
    func typeIntoField(_ text: String) throws {
      try click(#require(firstTextField))
      try type(text)
    }
  }
#endif
