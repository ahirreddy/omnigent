import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents
@testable import OmnigentWorkspaceUI

/// The new transcript markers: notices, a message from another session, and sub-agent, task and
/// plan markers, with a notice and a message opened.
struct LookMarkers: View {
  @State private var disclosures: TranscriptDisclosures = {
    let disclosures = TranscriptDisclosures()
    disclosures.choice("notice-n2").isExpanded = true
    disclosures.choice(SessionOrigin.disclosureKey("m2")).isExpanded = true
    return disclosures
  }()

  private static func activity(
    _ id: String, _ kind: ActivityKind, title: String, summary: String = "",
    status: String? = nil, details: [DetailSection] = []
  ) -> Row {
    Row(
      id: id, role: .tool,
      activity: Activity(
        kind: kind, title: title, summary: summary, status: status, details: details))
  }

  private var actions: ConversationActions {
    var actions = ConversationActions()
    actions.sessionTitle = { $0 == "peer" ? "Peer review" : nil }
    actions.openSession = { _ in }
    actions.openChild = { _ in }
    return actions
  }

  var body: some View {
    let timerDetails = [DetailSection(id: "body", title: "Details", text: "note: check the build")]
    let session = [DetailSection(id: "session", title: "Session", text: "child-1", isCode: true)]
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
      ActivityRowView(
        row: Self.activity(
          "n1", .systemNotice, title: "Timer t1 fired", summary: "note: check the build",
          status: "timer_fired", details: timerDetails))
      ActivityRowView(
        row: Self.activity(
          "n2", .systemNotice, title: "Task build completed", summary: "Compiled",
          status: "task_completed",
          details: [DetailSection(id: "body", title: "Details", text: "Compiled 214 files in 41s.")]
        ))
      ActivityRowView(
        row: Self.activity(
          "n3", .systemNotice, title: "Terminal shell:s1 idle", status: "terminal_idle"))
      MessageRowView(
        row: Row(
          id: "m1", role: .user, text: "Can you review PR 12?\nIt is small.",
          originSessionId: "peer"),
        decoration: MessageDecoration())
      MessageRowView(
        row: Row(
          id: "m2", role: .user, text: "The fix is in. Can you rerun the suite?",
          originSessionId: "peer"),
        decoration: MessageDecoration())
      ActivityRowView(
        row: Self.activity(
          "s1", .subagentMarker, title: "Started", summary: "Explore auth", status: "started",
          details: session))
      ActivityRowView(
        row: Self.activity(
          "s2", .subagentMarker, title: "Completed", summary: "Explore auth", status: "returned",
          details: session))
      ActivityRowView(
        row: Self.activity(
          "t1", .taskMarker, title: "Waiting for you on", summary: "Review the plan",
          status: "needs_input"))
      ActivityRowView(
        row: Self.activity(
          "t2", .taskMarker, title: "Made a plan: Ship it \u{00B7} 2 tasks", status: "plan"))
    }
    .padding(Theme.Spacing.large)
    .environment(\.conversationActions, actions)
    .environment(\.transcriptDisclosures, disclosures)
  }
}

/// A sent message with its action row shown, Edit and resend among them.
struct LookEditResend: View {
  @FocusState private var focused: Bool

  private var actions: ConversationActions {
    var actions = ConversationActions()
    actions.editSentMessage = { _ in }
    actions.messageURL = { _ in URL(string: "https://example.com/m") }
    return actions
  }

  var body: some View {
    let row = Row(
      id: "u1", role: .user, text: "Make the retry back off exponentially.",
      responseId: "r1", createdAt: LookFixtures.now)
    VStack(alignment: .trailing, spacing: Theme.Spacing.small) {
      MessageRowView(row: row, decoration: MessageDecoration(timestamp: LookFixtures.now))
      MessageActionRow(row: row, actions: actions, timestamp: LookFixtures.now, focus: $focused)
    }
    .padding(Theme.Spacing.large)
    .environment(\.conversationActions, actions)
    .contextMenu { MessageContextMenu(row: row, actions: actions) }
  }
}

/// The sample workspace with chapters for its recording.
@MainActor
final class LookChapteredSource: WorkspaceDataSource {
  private let sample = SampleWorkspaceDataSource()

  // swiftlint:disable async_without_await
  func videoChapters(_ path: String) async -> VideoChapters {
    VideoChapters(
      file: "\(path).chapters.vtt",
      chapters: [
        VideoChapter(time: 0, end: 5, title: "Sign in"),
        VideoChapter(time: 5, end: 9, title: "Open the settings"),
        VideoChapter(time: 9, end: 14, title: "Turn on notifications"),
      ])
  }

  func listDirectory(_ path: String, after cursor: String?) async throws(WorkspaceFailure)
    -> DirectoryPage
  { try await sample.listDirectory(path, after: cursor) }
  func readFile(_ path: String) async throws(WorkspaceFailure) -> WorkspaceFile {
    try await sample.readFile(path)
  }
  func searchPaths(_ query: String, include: String, exclude: String)
    async throws(WorkspaceFailure) -> PathSearchResult
  { try await sample.searchPaths(query, include: include, exclude: exclude) }
  func searchContent(_ query: ContentSearchQuery) async throws(WorkspaceFailure)
    -> ContentSearchResult
  { try await sample.searchContent(query) }
  func changes() async throws(WorkspaceFailure) -> ChangesList { try await sample.changes() }
  func diff(_ path: String) async throws(WorkspaceFailure) -> FileDiff {
    try await sample.diff(path)
  }
  func absoluteLocation(of path: String) -> String? { nil }
  func save(_ path: String, text: String, base: String?) async throws(WorkspaceFailure)
    -> FileSaveResult
  { try await sample.save(path, text: text, base: base) }
  func comments(on path: String, text: String) async throws(WorkspaceFailure)
    -> [FileCommentLine]
  { [] }
  func addComment(_ body: String, on span: FileTextSpan) async throws(WorkspaceFailure) {}
  // swiftlint:disable:next discouraged_optional_boolean
  func updateComment(_ id: String, body: String?, open: Bool?) async throws(WorkspaceFailure) {}
  func deleteComment(_ id: String) async throws(WorkspaceFailure) {}
  func sendCommentsToAgent(_ ids: [String]) async throws(WorkspaceFailure) {}
  // swiftlint:enable async_without_await
}
