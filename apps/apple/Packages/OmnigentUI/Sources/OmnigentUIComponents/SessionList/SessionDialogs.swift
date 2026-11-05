import SwiftUI

/// Sessions waiting on the delete sheet with branch cleanup.
private struct BranchDeletion: Identifiable {
  let sessions: [SessionSummary]
  let isBulk: Bool
  var id: [String] { sessions.map(\.id) }
}

/// The sidebar's session prompts: Rename, and the Delete, bulk Delete, Leave and Stop
/// confirmations.
struct SessionDialogs: ViewModifier {
  @Binding var renaming: SessionSummary?
  @Binding var renameText: String
  @Binding var confirmingDelete: SessionSummary?
  @Binding var confirmingBulkDelete: [SessionSummary]
  @Binding var confirmingLeave: SessionSummary?
  @Binding var confirmingStop: SessionSummary?
  /// Per-session facts: whether Stop also stops a runner, and the worktree branch a delete
  /// can clean up.
  let rowInfo: [String: SessionRowInfo]
  let actions: SessionListActions
  /// Runs after a bulk delete is confirmed.
  let deletedMany: () -> Void

  /// The server's limit.
  static let maxTitleLength = 120

  func body(content: Content) -> some View {
    deleteDialogs(
      content
        .alert(
          "Rename Session",
          isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
          TextField("Title", text: $renameText)
          Button("Rename") {
            if let renaming, let rename = actions.rename { rename(renaming, trimmed) }
            renaming = nil
          }
          .disabled(trimmed.isEmpty || renameText.count > Self.maxTitleLength)
          Button("Cancel", role: .cancel) { renaming = nil }
        }
    )
    .confirmationDialog(
      "Leave this session?",
      isPresented: Binding(
        get: { confirmingLeave != nil }, set: { if !$0 { confirmingLeave = nil } }),
      presenting: confirmingLeave
    ) { session in
      Button("Leave", role: .destructive) { actions.leave?(session) }
    } message: { _ in
      Text("You lose access until someone shares it with you again.")
    }
  }

  /// Delete and bulk Delete: a confirmation, or the branch cleanup sheet for worktrees.
  private func deleteDialogs(_ content: some View) -> some View {
    content
      .confirmationDialog(
        "Delete this session?",
        isPresented: Binding(
          get: { confirmingDelete.map { !offersBranches([$0]) } ?? false },
          set: { if !$0 { confirmingDelete = nil } }),
        presenting: confirmingDelete
      ) { session in
        Button("Delete", role: .destructive) { actions.delete?(session) }
      } message: { _ in
        Text("This permanently deletes the session and its history.")
      }
      .confirmationDialog(
        bulkTitle,
        isPresented: Binding(
          get: { !confirmingBulkDelete.isEmpty && !offersBranches(confirmingBulkDelete) },
          set: { if !$0 { confirmingBulkDelete = [] } }),
        presenting: confirmingBulkDelete
      ) { sessions in
        Button("Delete", role: .destructive) {
          for session in sessions { actions.delete?(session) }
          deletedMany()
        }
      } message: { _ in
        Text("This permanently deletes the sessions and their history.")
      }
      .sheet(item: branchDeletion) { pending in
        DeleteSessionsSheet(
          sessions: pending.sessions, branches: rowInfo.compactMapValues(\.branch),
          delete: { branchIDs in
            for session in pending.sessions {
              actions.deleteWithBranch?(session, branchIDs.contains(session.id))
            }
            if pending.isBulk { deletedMany() }
            dismissBranchDeletion()
          },
          cancel: dismissBranchDeletion)
      }
      .stopSessionConfirmation(
        $confirmingStop, runsOnHost: { rowInfo[$0.id]?.runsOnHost == true }, stop: actions.stop)
  }

  private var trimmed: String { renameText.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// The web's branch cleanup applies when the host can delete branches and one has a branch.
  private func offersBranches(_ sessions: [SessionSummary]) -> Bool {
    actions.deleteWithBranch != nil && sessions.contains { rowInfo[$0.id]?.branch != nil }
  }

  private var branchDeletion: Binding<BranchDeletion?> {
    Binding(
      get: {
        if let session = confirmingDelete, offersBranches([session]) {
          return BranchDeletion(sessions: [session], isBulk: false)
        }
        if offersBranches(confirmingBulkDelete) {
          return BranchDeletion(sessions: confirmingBulkDelete, isBulk: true)
        }
        return nil
      },
      set: { if $0 == nil { dismissBranchDeletion() } })
  }

  private func dismissBranchDeletion() {
    if confirmingDelete != nil { confirmingDelete = nil }
    if !confirmingBulkDelete.isEmpty { confirmingBulkDelete = [] }
  }

  private var bulkTitle: String {
    confirmingBulkDelete.count == 1
      ? "Delete 1 session?" : "Delete \(confirmingBulkDelete.count) sessions?"
  }
}

/// The web's "Stop session?" confirmation, for the row menu and the session menu.
struct StopSessionConfirmation: ViewModifier {
  @Binding var confirming: SessionSummary?
  let runsOnHost: (SessionSummary) -> Bool
  let stop: (@MainActor (SessionSummary) -> Void)?

  func body(content: Content) -> some View {
    content.confirmationDialog(
      "Stop session?",
      isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
      presenting: confirming
    ) { session in
      Button("Stop session", role: .destructive) { stop?(session) }
        .accessibilityIdentifier("stop-session-confirm")
    } message: { session in
      Text(Self.message(session, runsOnHost: runsOnHost(session)))
    }
  }

  /// The web's explanation: a host session's runner stops too; histories are kept.
  static func message(_ session: SessionSummary, runsOnHost: Bool) -> String {
    let runner = runsOnHost ? " and stops its runner, including side chats running on it" : ""
    return
      "This terminates the running session for \u{201C}\(session.title)\u{201D}\(runner). Conversation histories are kept."
  }
}

extension View {
  /// Asks "Stop session?" while `confirming` is set, then calls `stop`.
  func stopSessionConfirmation(
    _ confirming: Binding<SessionSummary?>, runsOnHost: @escaping (SessionSummary) -> Bool,
    stop: (@MainActor (SessionSummary) -> Void)?
  ) -> some View {
    modifier(StopSessionConfirmation(confirming: confirming, runsOnHost: runsOnHost, stop: stop))
  }
}
