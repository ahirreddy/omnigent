#if os(macOS)
  import Foundation
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Pull request screens with hostile data", .serialized)
  struct PullRequestScreensRenderTests {
    private static var everyAction: PullRequestPanelActions {
      var actions = PullRequestPanelActions()
      actions.select = { _ in }
      actions.showList = {}
      actions.link = { _, done in done(true) }
      actions.unlink = { _ in }
      actions.refresh = {}
      actions.loadLabels = {}
      actions.setLabel = { _, _ in }
      actions.loadReviewers = {}
      actions.setReviewer = { _, _ in }
      actions.loadMergeMethods = {}
      actions.merge = { _ in }
      actions.disableAutoMerge = {}
      actions.comment = { _, done in done(true) }
      actions.dismissError = {}
      return actions
    }

    private static func extras(error: String? = nil, busy: Bool = false) -> PullRequestPanelExtras {
      var extras = PullRequestPanelExtras()
      extras.actions = everyAction
      extras.error = error
      extras.isBusy = busy
      return extras
    }

    private static var realistic: PullRequestDetailViewState {
      var state = PullRequestDetailViewState(
        url: "https://github.com/acme/app/pull/7", title: "Add the sidebar", numberLabel: "#7",
        status: .ready, context: "acme/app \u{00B7} sidebar \u{2192} main",
        providerName: "GitHub")
      state.body = "## Summary\n\nAdds the **sidebar**.\n\n- One\n- Two"
      state.checks = [
        PullRequestCheckGroup(
          bucket: .passed, count: 2,
          runs: [
            PullRequestCheckGroup.Run(name: "lint", url: URL(string: "https://example.com/1")),
            PullRequestCheckGroup.Run(name: "test", url: nil),
          ]),
        PullRequestCheckGroup(bucket: .failed, count: 1, runs: []),
      ]
      state.checksNote = "Some checks couldn't be read."
      state.reviewers = [
        PullRequestChip(
          id: "user:sam", title: "sam", detail: "Approved", systemImage: "checkmark.circle")
      ]
      state.showsReviewers = true
      state.labels = [PullRequestChip(id: "bug", title: "bug", color: 0xD7_3A_4A)]
      state.showsLabels = true
      state.merge = .ready(nil)
      state.comments = [
        PullRequestCommentRow(
          id: "c1", author: "sam", date: Date(timeIntervalSince1970: 1_793_880_000),
          body: "Looks **good**.", url: URL(string: "https://example.com/c1"))
      ]
      state.canEditLabels = true
      state.canEditReviewers = true
      state.canComment = true
      state.fileCount = 12
      return state
    }

    /// A lone PR with nothing but what its initializer takes, all of it blank.
    private static var blank: PullRequestDetailViewState {
      PullRequestDetailViewState(
        url: "", title: "", numberLabel: "", status: .unknown, context: "", providerName: "")
    }

    private static var hostile: PullRequestDetailViewState {
      let chips = (0..<HostileData.rowCount).map { index in
        PullRequestChip(
          id: "\(index)", title: HostileData.text(index), detail: HostileData.text(index + 1),
          systemImage: HostileData.text(index + 2), color: index.isMultiple(of: 2) ? UInt32.max : 0)
      }
      var state = PullRequestDetailViewState(
        url: HostileData.controlCharacters, title: HostileData.unbroken,
        numberLabel: HostileData.unbroken, status: .conflicts, context: HostileData.unbroken,
        providerName: HostileData.bidirectional)
      state.body = HostileData.samples.joined(separator: "\n\n")
      state.checks = PullRequestCheckGroup.Bucket.allCases.enumerated().map { index, bucket in
        PullRequestCheckGroup(
          bucket: bucket, count: index == 0 ? Int.max : -index,
          runs: (0..<HostileData.rowCount).map {
            PullRequestCheckGroup.Run(name: HostileData.text($0), url: nil)
          })
      }
      state.checksNote = HostileData.bidirectional
      state.reviewers = chips
      state.showsReviewers = true
      state.labels = chips
      state.showsLabels = true
      state.merge = .blocked(HostileData.bidirectional)
      state.comments = (0..<HostileData.rowCount).map { index in
        PullRequestCommentRow(
          id: "\(index)", author: HostileData.text(index), date: HostileData.date(index),
          body: HostileData.text(index + 1), url: nil)
      }
      state.commentsPartial = true
      state.canEditLabels = true
      state.canEditReviewers = true
      state.canComment = true
      state.fileCount = -1
      return state
    }

    private static func summary(merge: PullRequestMergeState) -> some View {
      var state = realistic
      state.merge = merge
      return PullRequestSummaryView(state: state, extras: extras(), open: { _ in })
    }

    nonisolated static let screens: [ScreenCase] = [
      ScreenCase("pr-detail-realistic", realistic: true) {
        PullRequestDetailView(
          content: .ready(realistic), extras: extras(), listCount: 3, open: { _ in })
      },
      ScreenCase("pr-detail-blank", realistic: true, narrowOnly: true) {
        PullRequestDetailView(
          content: .ready(blank), extras: PullRequestPanelExtras(), listCount: 0, open: nil)
      },
      ScreenCase("pr-detail-loading", narrowOnly: true) {
        PullRequestDetailView(content: .loading, extras: extras(), listCount: -1, open: nil)
      },
      ScreenCase("pr-detail-failed", narrowOnly: true) {
        PullRequestDetailView(
          content: .failed(HostileData.unbroken), extras: extras(error: HostileData.unbroken),
          listCount: Int.max, open: nil)
      },
      ScreenCase("pr-detail-unavailable", narrowOnly: true) {
        PullRequestDetailView(
          content: .unavailable(
            title: HostileData.unbroken, message: HostileData.bidirectional,
            systemImage: "not.a.symbol"),
          extras: extras(), listCount: 0, open: nil)
      },
      ScreenCase("pr-detail-hostile") {
        PullRequestDetailView(
          content: .ready(hostile), extras: extras(error: HostileData.bidirectional, busy: true),
          listCount: Int.max, open: { _ in })
      },
      // The detail's Summary tab draws the rest of the summary and its people.
      ScreenCase("pr-summary-blank", realistic: true, narrowOnly: true) {
        PullRequestSummaryView(state: blank, extras: PullRequestPanelExtras(), open: nil)
      },
      ScreenCase("pr-summary-auto-merge", narrowOnly: true) { summary(merge: .autoMerge) },
      ScreenCase("pr-summary-checking", narrowOnly: true) {
        summary(merge: .checking(HostileData.unbroken))
      },
      ScreenCase("pr-summary-ready-caveat", narrowOnly: true) {
        summary(merge: .ready(HostileData.bidirectional))
      },
      ScreenCase("pr-comments-hostile", narrowOnly: true) {
        PullRequestCommentsView(state: hostile, extras: extras(), open: { _ in })
      },
      ScreenCase("pr-reviewers-empty", height: nil, narrowOnly: true) {
        PullRequestReviewersSection(reviewers: [], editable: false, extras: extras())
      },
      ScreenCase("pr-reviewers-hostile", height: nil, narrowOnly: true) {
        PullRequestReviewersSection(reviewers: hostile.reviewers, editable: true, extras: extras())
      },
      ScreenCase("pr-labels-empty", height: nil, narrowOnly: true) {
        PullRequestLabelsSection(labels: [], editable: false, extras: extras())
      },
      ScreenCase("pr-labels-hostile", height: nil, narrowOnly: true) {
        PullRequestLabelsSection(labels: hostile.labels, editable: true, extras: extras())
      },
      ScreenCase("pr-choices-loaded", realistic: true, narrowOnly: true) {
        PullRequestChoiceList(
          title: HostileData.unbroken, choices: .loaded(hostile.labels), selected: ["0", "gone"],
          toggle: { _, _ in })
      },
      ScreenCase("pr-choices-failed", narrowOnly: true) {
        PullRequestChoiceList(
          title: "", choices: .failed(HostileData.unbroken), selected: [], toggle: { _, _ in })
      },
      ScreenCase("pr-choices-idle", narrowOnly: true) {
        PullRequestChoiceList(title: "", choices: .idle, selected: [], toggle: { _, _ in })
      },
    ]

    @Test("renders without crashing or hanging", arguments: screens)
    func render(screen: ScreenCase) throws {
      try ScreenRenderer.check(screen)
    }
  }

  @Suite("Pull request tab titles")
  struct PullRequestTabTitleTests {
    private let state = PullRequestDetailViewState(
      url: "", title: "", numberLabel: "", status: .open, context: "", providerName: "")

    @Test("Comments counts them, with a plus when some couldn't be read")
    func commentsTitle() {
      var state = state
      #expect(PullRequestDetailTab.comments.title(state) == "Comments")
      state.commentsPartial = true
      #expect(PullRequestDetailTab.comments.title(state) == "Comments", "nothing to count")
      state.comments = [
        PullRequestCommentRow(id: "c", author: "a", date: nil, body: "", url: nil)
      ]
      #expect(PullRequestDetailTab.comments.title(state) == "Comments 1+")
      state.commentsPartial = false
      #expect(PullRequestDetailTab.comments.title(state) == "Comments 1")
    }

    @Test("Changes counts files once the patch is read, including none")
    func changesTitle() {
      var state = state
      #expect(PullRequestDetailTab.changes.title(state) == "Changes")
      state.fileCount = 0
      #expect(PullRequestDetailTab.changes.title(state) == "Changes 0")
      #expect(PullRequestDetailTab.summary.title(state) == "Summary")
    }

    @Test("every check bucket has its own symbol")
    func bucketSymbols() {
      let symbols = PullRequestCheckGroup.Bucket.allCases.map(PullRequestChecksSection.symbol)
      #expect(Set(symbols).count == symbols.count)
    }
  }
#endif
