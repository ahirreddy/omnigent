import Foundation
import SwiftUI

@testable import OmnigentUIComponents

/// Generic data for the screens the parity sweep changed: the Pull Requests tab's rows,
/// composers, reviewers, merge account and suggestions.
@MainActor
enum SweepLookFixtures {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)
  static let url = "https://example.com/acme/app/pull/42"

  static func summary(_ id: Int, _ title: String, _ status: PullRequestSummary.Status)
    -> PullRequestSummary
  {
    PullRequestSummary(
      id: "\(url)\(id)", number: id, title: title, repo: "acme/app", url: "\(url)\(id)",
      status: status, detail: "Created in this session")
  }

  static func list(offline: Bool) -> some View {
    let rows = [
      summary(42, "Retry uploads on timeout", .failing),
      summary(43, "Add the settings search", .running),
      summary(44, "Tidy the README", .merged),
    ]
    var extras = PullRequestPanelExtras()
    extras.actions.select = { _ in }
    extras.actions.link = { _, _ in }
    extras.actions.unlink = { _ in }
    for row in rows {
      var item = PullRequestRowExtras()
      if offline {
        item.offline = PullRequestOfflineNote(
          title: "Sandbox asleep",
          hint: "To load the PR details, send a message to start the session\u{2019}s sandbox.")
      } else if row.number == 42 {
        item.failing = 2
        item.pending = 1
      } else if row.number == 43 {
        item.pending = 4
      }
      if !item.isEmpty { extras.rows[row.url] = item }
    }
    return PullRequestsPanel(
      state: .loaded(rows, synced: true), extras: extras, open: nil, refresh: {})
  }

  static var detail: PullRequestDetailViewState {
    var state = PullRequestDetailViewState(
      url: url, title: "Retry uploads on timeout", numberLabel: "#42", status: .ready,
      context: "acme/app \u{00B7} retry \u{2192} main", providerName: "GitHub")
    state.showsReviewers = true
    state.canEditReviewers = true
    state.reviewers = [
      PullRequestChip(id: "user:sam", title: "sam", detail: "Pending", systemImage: "clock"),
      PullRequestChip(
        id: "user:kim", title: "kim", detail: "Approved", systemImage: "checkmark.circle"),
    ]
    state.requestedReviewers = ["user:sam"]
    state.merge = .ready(nil)
    state.account = "dev-bot"
    state.mergeAccounts = [
      PullRequestAccountChoice(login: "dev", active: true),
      PullRequestAccountChoice(login: "dev-bot", active: false, selected: true),
    ]
    state.canComment = true
    state.comments = [
      PullRequestCommentRow(
        id: "c1", author: "sam", date: now.addingTimeInterval(-7_200),
        body: "Could this retry use **backoff**?", url: URL(string: "https://example.com/c1")),
      PullRequestCommentRow(
        id: "c2", author: "dev-bot", date: now.addingTimeInterval(-3_600),
        body: "Done \u{2014} it waits 1, 2, then 4 seconds.", url: nil),
      PullRequestCommentRow(
        id: "c3", author: "kim", date: now.addingTimeInterval(-600), body: "Looks good.",
        url: nil),
    ]
    return state
  }

  static var extras: PullRequestPanelExtras {
    var extras = PullRequestPanelExtras()
    extras.actions.setReviewer = { _, _ in }
    extras.actions.loadReviewers = {}
    extras.actions.merge = { _ in }
    extras.actions.mergeAs = { _, _ in }
    extras.actions.setAccount = { _ in }
    extras.actions.loadMergeMethods = {}
    extras.actions.comment = { _, done in done(true) }
    return extras
  }

  static var summaryTab: some View {
    PullRequestSummaryView(state: detail, extras: extras, open: nil)
  }

  static var commentsTab: some View {
    PullRequestCommentsView(
      state: detail, extras: extras, open: nil, keptDraft: .constant("Thanks, merging now."))
  }

  static var suggestion: some View {
    let comments = [
      PullRequestReviewCommentRow(
        id: "s1", author: "sam", date: now.addingTimeInterval(-1_800),
        body: "Name the constant:\n```suggestion\nlet retryLimit = 3\nlet backoff = 1.0\n```",
        url: nil, hidden: false),
      PullRequestReviewCommentRow(
        id: "s2", author: "kim", date: now.addingTimeInterval(-900),
        body: "Or drop it:\n```suggestion\n```", url: nil, hidden: false),
    ]
    var thread = PullRequestReviewThreadState(id: "t1", lineLabel: "Line 18", comments: comments)
    thread.canReply = true
    thread.suggestionSource = PullRequestSuggestionSource(
      line: 18, lines: ["let limit = 3"], original: false)
    var moved = PullRequestReviewThreadState(
      id: "t2", lineLabel: "Line 30", comments: [comments[0]])
    moved.outdated = true
    var actions = PullRequestReviewActions()
    actions.reply = { _ in }
    actions.setReply = { _, _ in }
    actions.account = "dev-bot"
    return PullRequestReviewThreadsView(threads: [thread, moved], actions: actions)
      .padding(Theme.Spacing.medium)
  }

  static var unresolved: some View {
    var extras = PullRequestPanelExtras()
    extras.actions.setAccount = { _ in }
    extras.accountChoices = [
      PullRequestAccountChoice(login: "dev", active: true),
      PullRequestAccountChoice(login: "dev-bot", active: false),
    ]
    return PullRequestDetailView(
      content: .unavailable(
        title: "Can\u{2019}t reach the upstream repo",
        message:
          "Pick the account to use, or run `gh auth status` on the host to confirm the GitHub "
          + "CLI is signed in.",
        systemImage: "key"),
      extras: extras, listCount: 1, open: nil)
  }

  static var remote: some View {
    PullRequestDetailView(
      content: .unavailable(
        title: "No supported remote",
        message: "Omnigent couldn\u{2019}t identify the git provider for `git.example.com`.\n\n"
          + "On the execution host, run `glab auth login --hostname git.example.com` for GitLab "
          + "or `gh auth login --hostname git.example.com` for GitHub Enterprise.",
        systemImage: "server.rack"),
      extras: PullRequestPanelExtras(), listCount: 1, open: nil)
  }

  static var toolFields: some View {
    let input = ToolFieldValue.fields(
      json: #"{"path":"App/Retry.swift","limit":40,"recursive":false,"options":{"depth":2}}"#)
    let output = #"{"matches":3,"files":["Retry.swift","Upload.swift"],"truncated":false}"#
    return ToolFieldsBody(input: input, output: output).padding(Theme.Spacing.medium)
  }

  static var smartRouting: some View {
    let arguments = #"""
      {"tasks":[{"title":"Fix the login retry","agents":[{"agent":"codex"}]},
                {"title":"Write the release notes","agents":[{"agent":"claude"}]}]}
      """#
    let output = #"""
      {"recommendations":[
        {"title":"Fix the login retry","model":"databricks-claude-opus-4","agent":"codex",
         "rationale":"A subtle concurrency bug across three files."},
        {"title":"Write the release notes","model":"databricks-claude-haiku-4",
         "rationale":"Short prose from a known change list."}]}
      """#
    return SmartRoutingCardView(
      plan: .read(arguments: arguments, output: output), isJudging: false, output: output
    )
    .padding(Theme.Spacing.medium)
  }
}
