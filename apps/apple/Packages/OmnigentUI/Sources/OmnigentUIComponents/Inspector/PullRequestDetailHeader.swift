import SwiftUI

/// The open PR's repository and branches, then its title, number and status. Editors change the
/// title in place, as the web's `PullRequestTitle` does.
struct PullRequestDetailHeader: View {
  let state: PullRequestDetailViewState
  let extras: PullRequestPanelExtras

  /// The title being edited; `nil` shows it.
  @State private var draft: String?
  @FocusState private var focused: Bool

  /// The provider's title limit.
  static let maxTitleLength = 256

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      Text(state.context)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(state.context)
      if let draft {
        editor(draft)
      } else {
        title
      }
    }
    .onChange(of: state.url) { draft = nil }
  }

  private var title: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
      Text(state.title)
        .font(.headline)
        .lineLimit(3)
        .textSelection(.enabled)
      Text(state.numberLabel).foregroundStyle(.secondary)
      if state.canEditDetails, extras.actions.editDetails != nil {
        Button {
          draft = state.title
        } label: {
          Image(systemName: "pencil").accessibilityLabel("Edit title")
        }
        .buttonStyle(.borderless)
        .help("Edit title")
        .accessibilityIdentifier("pr-edit-title")
      }
      Spacer(minLength: 0)
      PullRequestStatusChip(status: state.status)
    }
  }

  private func editor(_ text: String) -> some View {
    HStack(spacing: Theme.Spacing.small) {
      TextField("Pull request title", text: Binding(get: { text }, set: { draft = $0 }))
        .textFieldStyle(.roundedBorder)
        .focused($focused)
        .disabled(extras.isBusy)
        .onSubmit(save)
        .onKeyPress(.escape) {
          draft = nil
          return .handled
        }
        .onChange(of: text) { _, value in
          if value.count > Self.maxTitleLength { draft = String(value.prefix(Self.maxTitleLength)) }
        }
        .accessibilityIdentifier("pr-title-field")
      Button(extras.isBusy ? "Saving\u{2026}" : "Save", action: save)
        .disabled(extras.isBusy || text.trimmingCharacters(in: .whitespaces).isEmpty)
      Button("Cancel") { draft = nil }
    }
    .onAppear { focused = true }
  }

  private func save() {
    let next = (draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !extras.isBusy else { return }
    guard !next.isEmpty, next != state.title, let edit = extras.actions.editDetails else {
      draft = nil
      return
    }
    edit(next, nil) { saved in
      if saved { draft = nil }
    }
  }
}
