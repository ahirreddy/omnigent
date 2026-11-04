import SwiftUI

/// The sidebar's session prompts: Rename, and the Delete, bulk Delete and Leave confirmations.
struct SessionDialogs: ViewModifier {
  @Binding var renaming: SessionSummary?
  @Binding var renameText: String
  @Binding var confirmingDelete: SessionSummary?
  @Binding var confirmingBulkDelete: [SessionSummary]
  @Binding var confirmingLeave: SessionSummary?
  let actions: SessionListActions
  /// Runs after a bulk delete is confirmed.
  let deletedMany: () -> Void

  /// The server's limit.
  static let maxTitleLength = 120

  func body(content: Content) -> some View {
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
      .confirmationDialog(
        "Delete this session?",
        isPresented: Binding(
          get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
        presenting: confirmingDelete
      ) { session in
        Button("Delete", role: .destructive) { actions.delete?(session) }
      } message: { _ in
        Text("This permanently deletes the session and its history.")
      }
      .confirmationDialog(
        bulkTitle,
        isPresented: Binding(
          get: { !confirmingBulkDelete.isEmpty }, set: { if !$0 { confirmingBulkDelete = [] } }),
        presenting: confirmingBulkDelete
      ) { sessions in
        Button("Delete", role: .destructive) {
          for session in sessions { actions.delete?(session) }
          deletedMany()
        }
      } message: { _ in
        Text("This permanently deletes the sessions and their history.")
      }
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

  private var trimmed: String { renameText.trimmingCharacters(in: .whitespacesAndNewlines) }

  private var bulkTitle: String {
    confirmingBulkDelete.count == 1
      ? "Delete 1 session?" : "Delete \(confirmingBulkDelete.count) sessions?"
  }
}
