import SwiftUI

/// The web's delete confirmation for sessions with worktrees: a table of each session's local
/// git branch with a checkbox to delete it too (opt-in, since it cannot be undone), and an
/// All checkbox for several.
struct DeleteSessionsSheet: View {
  /// The sessions to delete.
  let sessions: [SessionSummary]
  /// Each session's worktree branch, by session id; sessions without one are not listed.
  let branches: [String: String]
  /// Deletes, with the ids whose branch to delete.
  let delete: @MainActor (_ branchIDs: Set<String>) -> Void
  let cancel: @MainActor () -> Void

  @State private var chosen: Set<String> = []

  private var withBranch: [SessionSummary] { sessions.filter { branches[$0.id] != nil } }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      Text(sessions.count == 1 ? "Delete this session?" : "Delete \(sessions.count) sessions?")
        .font(.headline)
      Text(
        "This permanently deletes the \(sessions.count == 1 ? "session" : "sessions") and all "
          + "\(sessions.count == 1 ? "its" : "their") history. This cannot be undone."
      )
      .foregroundStyle(.secondary)
      if !withBranch.isEmpty { branchTable }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: cancel)
          .keyboardShortcut(.cancelAction)
        Button("Delete", role: .destructive) { delete(chosen) }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("delete-sessions-confirm")
      }
    }
    .padding(Theme.Spacing.large)
    .frame(width: 460)
    .accessibilityIdentifier("delete-sessions-sheet")
  }

  private var branchTable: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text(
        "Optionally delete the local git branches of these worktree sessions. This is "
          + "irreversible."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      if withBranch.count > 1 {
        Toggle("All branches", isOn: allBinding)
          .checkboxStyle()
          .accessibilityIdentifier("delete-branches-all")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          ForEach(withBranch) { session in
            Toggle(isOn: binding(session.id)) {
              VStack(alignment: .leading, spacing: 2) {
                Label(branches[session.id] ?? "", systemImage: "arrow.triangle.branch")
                  .font(Theme.codeFont)
                Text(session.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
              }
            }
            .checkboxStyle()
            .accessibilityLabel("Delete branch \(branches[session.id] ?? "")")
            .accessibilityIdentifier("delete-branch-checkbox")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 220)
    }
    .padding(Theme.Spacing.medium)
    .background(
      Theme.failure.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
  }

  private func binding(_ id: String) -> Binding<Bool> {
    Binding(
      get: { chosen.contains(id) },
      set: { isOn in
        if isOn { chosen.insert(id) } else { chosen.remove(id) }
      })
  }

  private var allBinding: Binding<Bool> {
    Binding(
      get: { withBranch.allSatisfy { chosen.contains($0.id) } },
      set: { isOn in chosen = isOn ? Set(withBranch.map(\.id)) : [] })
  }
}

extension View {
  /// A checkbox on the Mac; the platform's switch elsewhere.
  @ViewBuilder func checkboxStyle() -> some View {
    #if os(macOS)
      toggleStyle(.checkbox)
    #else
      self
    #endif
  }
}
