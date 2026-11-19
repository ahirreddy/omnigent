import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents
@testable import OmnigentWorkspaceUI

/// Generic data for each screen.
@MainActor
enum LookFixtures {
  static let now = Date(timeIntervalSince1970: 1_795_080_500)

  // MARK: Decisions

  static func card(_ card: DecisionCard, draft: FormDraft = FormDraft()) -> some View {
    LookDecision(card: card, draft: draft)
  }

  static var questionDraft: FormDraft {
    var draft = FormDraft()
    draft.selected = [
      "Which layout should the settings screen use?": ["Sidebar"],
      "Which platforms need the change?": ["Mac"],
    ]
    draft.notes = ["Which layout should the settings screen use?": "Keep the list collapsible."]
    return draft
  }

  static var formDraft: FormDraft {
    var draft = FormDraft()
    draft.text = ["title": "Share one refresh across callers", "reviewers": "2"]
    draft.booleans = ["draft": true]
    draft.selected = ["base": ["main"], "labels": ["auth"]]
    return draft
  }

  static let dates = PreviewData.card(
    "elic_dates", title: "Response requested", detail: "When should the release go out?",
    kind: .form(fields: [
      FormField(
        key: "day", title: "Release day", detail: "The day the build ships.", kind: .text,
        format: .date),
      FormField(
        key: "freeze", title: "Code freeze", kind: .text, required: false, format: .dateTime),
      FormField(key: "owner", title: "Release owner", kind: .text, format: .email),
      FormField(key: "notes", title: "Site", kind: .text, required: false, format: .uri),
    ]))

  static var datesDraft: FormDraft {
    var draft = FormDraft()
    draft.text = ["day": "2026-12-01", "owner": "owner@example.com"]
    return draft
  }

  // MARK: Composer

  static var rewind: some View {
    RewindPickerSheet(
      state: RewindPickerState(
        phase: .loaded,
        prompts: [
          .init(id: "m5", text: "Add a test for the parser's error path"),
          .init(id: "m4", text: "Now make the retry back off exponentially"),
          .init(id: "m3", text: ""),
          .init(id: "m2", text: "Fix the parser so it accepts trailing commas"),
          .init(id: "m1", text: "Read the parser and explain how it handles lists"),
        ], older: .available),
      actions: RewindPickerActions(choose: { _ in }, loadOlder: {}, dismiss: {}))
  }

  static var mcpBar: some View {
    var options = NewSessionOptions(
      folder: "/workspace/app", recentFolders: ["/workspace/app"], offersWorktrees: true)
    options.mcpServices = McpLaunchServices(
      phase: .loaded,
      services: [
        .init(id: "docs", title: "Docs search", connection: .connected, isSelected: true),
        .init(id: "tracker", title: "Issue tracker", connection: .needsSignIn, isSelected: true),
      ], selectedCount: 2)
    var actions = NewSessionOptionActions(selectFolder: { _ in }, selectWorktree: { _ in })
    actions.mcpServices = McpLaunchActions(toggle: { _, _ in }, reload: {})
    return NewSessionOptionsBar(options: options, actions: actions)
      .padding(Theme.Spacing.medium)
  }

  // MARK: Pull requests

  private static var diffFiles: [StackedDiffFile] {
    [
      StackedDiffFile(diff: WorkspaceSamples.mainDiff),
      StackedDiffFile(diff: WorkspaceSamples.libDiff),
    ]
  }

  private static var changesActions: PullRequestChangesActions {
    var actions = PullRequestChangesActions()
    actions.setFindOpen = { _ in }
    actions.setFindQuery = { _ in }
    actions.stepFind = { _ in }
    actions.toggleMatchCase = {}
    actions.toggleRegex = {}
    actions.showHidden = {}
    actions.setLayout = { _ in }
    actions.toggleAll = {}
    actions.setHideViewed = { _ in }
    actions.jumpToFile = { _ in }
    actions.openCommit = { _ in }
    actions.showCommits = { _ in }
    actions.setPathFilter = { _ in }
    actions.setCommitQuery = { _ in }
    actions.navigateThread = { _ in }
    return actions
  }

  static func changes(find: Bool) -> some View {
    var state = PullRequestChangesState()
    state.showsFileControls = true
    state.offersCommits = true
    state.offersFilter = true
    state.canNavigateThreads = true
    var findState = PullRequestFindState()
    if find {
      findState.isOpen = true
      findState.query = "parse"
      findState.status = "2 of 5"
      findState.total = 5
      findState.hidden = "+1 in hidden files"
      findState.matchCase = true
    }
    state.find = findState
    state.progress = PullRequestViewedProgress(
      viewed: 1, total: 2, partial: false, hideViewed: false)
    state.treeFiles = diffFiles.map {
      PullRequestTreeFile(path: $0.path, kind: $0.kind, added: $0.added, removed: $0.removed)
    }
    state.viewedPaths = [diffFiles[1].path]
    state.activePath = diffFiles[0].path
    state.body = .diff(StackedDiffContent(files: diffFiles))
    return PullRequestChangesView(state: state, actions: changesActions)
  }

  static var commits: some View {
    var list = PullRequestCommitsState()
    list.commits = [
      PullRequestCommitRow(
        sha: "4f3c2a1b9e", title: "Parse trailing commas", author: "dev",
        date: now.addingTimeInterval(-7_200), headOf: nil),
      PullRequestCommitRow(
        sha: "9a8b7c6d5e", title: "Back off between retries", author: "dev",
        date: now.addingTimeInterval(-3_600), headOf: nil),
      PullRequestCommitRow(
        sha: "1234abcd99", title: "Add the parser's error tests", author: "reviewer",
        date: now.addingTimeInterval(-600), headOf: "main"),
    ]
    var state = PullRequestChangesState()
    state.offersCommits = true
    state.showsCommitList = true
    state.body = .commits(list)
    return PullRequestChangesView(state: state, actions: changesActions)
  }

  static var threads: some View {
    let comments = [
      PullRequestReviewCommentRow(
        id: "c1", author: "reviewer", date: now.addingTimeInterval(-3_600),
        body: "Should this retry on a timeout too?", url: URL(string: "https://example.com/c1"),
        hidden: false),
      PullRequestReviewCommentRow(
        id: "c2", author: "dev", date: now.addingTimeInterval(-600),
        body: "Yes \u{2014} timeouts go through the same path now.", url: nil, hidden: false),
    ]
    var open = PullRequestReviewThreadState(id: "t1", lineLabel: "Line 42", comments: comments)
    open.canReply = true
    var resolved = PullRequestReviewThreadState(
      id: "t2", lineLabel: "Lines 50\u{2013}52", comments: [comments[0]])
    resolved.resolved = true
    var actions = PullRequestReviewActions()
    actions.reply = { _ in }
    actions.setReply = { _, _ in }
    actions.setNewBody = { _ in }
    actions.postNew = {}
    actions.cancelNew = {}
    actions.setNewToAgent = { _ in }
    var newThread = PullRequestNewThreadState(
      lineLabel: "Line 18", body: "Can we name this constant?", problem: nil)
    newThread.offersAgent = true
    return PullRequestReviewThreadsView(
      threads: [open, resolved], newThread: newThread,
      localComments: [
        PullRequestLocalCommentState(
          id: "l1", lineLabel: "New lines 10\u{2013}12", earlier: false, addressed: false,
          body: "Split this function before the agent continues.", canEdit: true)
      ], actions: actions, localActions: localCommentActions
    )
    .padding(Theme.Spacing.medium)
  }

  private static var localCommentActions: PullRequestLocalCommentActions {
    var actions = PullRequestLocalCommentActions()
    actions.edit = { _, _, _ in }
    actions.delete = { _ in }
    return actions
  }

  static var fileHeader: some View {
    var viewed = PullRequestFileActionsState(
      path: "Sources/App/Parser.swift", previousPath: nil, openLabel: "Open on the provider",
      openURL: URL(string: "https://example.com/file"), openUnavailable: "")
    viewed.conversations = 2
    viewed.offersViewed = true
    viewed.viewed = true
    viewed.changedSinceViewed = true
    var unviewed = viewed
    unviewed.viewed = false
    unviewed.changedSinceViewed = false
    unviewed.conversations = 0
    let file = StackedDiffFile(diff: WorkspaceSamples.mainDiff)
    return VStack(spacing: 0) {
      StackedFileHeader(
        file: file, isCollapsed: false,
        accessory: AnyView(
          PullRequestFileActionsView(state: viewed, toggleEarlier: nil, toggleViewed: {})),
        toggle: {})
      StackedFileHeader(
        file: StackedDiffFile(diff: WorkspaceSamples.libDiff), isCollapsed: true,
        accessory: AnyView(
          PullRequestFileActionsView(state: unviewed, toggleEarlier: nil, toggleViewed: {})),
        toggle: {})
    }
  }

}

/// A decision card holding its own draft, as the dock does.
private struct LookDecision: View {
  let card: DecisionCard
  @State private var draft: FormDraft

  init(card: DecisionCard, draft: FormDraft) {
    self.card = card
    _draft = State(initialValue: draft)
  }

  var body: some View {
    DecisionCardView(
      card: card, phase: .pending, isReadOnly: false, context: "Claude Code",
      respond: { _ in }, validate: { PreviewData.validate(card, $0) }, draft: $draft
    )
    .padding(Theme.Spacing.medium)
  }
}
