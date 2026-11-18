import SwiftUI

/// The Commits view: the PR's commits, oldest first, with a search; one opens its patch.
struct PullRequestCommitsList: View {
  let state: PullRequestCommitsState
  let actions: PullRequestChangesActions

  var body: some View {
    if state.isUnavailable {
      message("Commits are unavailable.")
    } else if let error = state.error, state.commits.isEmpty {
      message(error, failure: true)
    } else if state.isLoading, state.commits.isEmpty {
      VStack(spacing: Theme.Spacing.small) {
        ProgressView()
        Text("Loading commits\u{2026}").foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      list
    }
  }

  private var list: some View {
    VStack(spacing: 0) {
      HStack {
        Text(state.commits.count == 1 ? "1 commit" : "\(state.commits.count) commits")
          .fontWeight(.medium)
        Spacer(minLength: 0)
        if state.hasMore {
          Text("History limited to \(state.limit) commits")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .font(.callout)
      .padding(Theme.Spacing.small)
      Divider()
      if let error = state.error {
        Text(error).font(.caption).foregroundStyle(Theme.failure).padding(Theme.Spacing.small)
        Divider()
      }
      TextField(
        "Search commits\u{2026}",
        text: Binding(get: { state.query }, set: { actions.setCommitQuery?($0) })
      )
      .textFieldStyle(.roundedBorder)
      .onKeyPress(.escape) {
        guard !state.query.isEmpty else { return .ignored }
        actions.setCommitQuery?("")
        return .handled
      }
      .accessibilityLabel("Search commits")
      .padding(Theme.Spacing.small)
      Divider()
      let visible = PullRequestCommitRow.filter(state.commits, query: state.query)
      if state.commits.isEmpty {
        message("No commits on this pull request.")
      } else if visible.isEmpty {
        let among = state.hasMore ? " among the first \(state.limit)" : ""
        message("No commits match \"\(state.query.trimmingCharacters(in: .whitespaces))\"\(among)")
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(visible) { commit in
              row(commit)
              Divider()
            }
          }
        }
      }
    }
    .accessibilityIdentifier("pr-commits")
  }

  private func row(_ commit: PullRequestCommitRow) -> some View {
    Button {
      actions.openCommit?(commit.sha)
    } label: {
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        Text(commit.title.isEmpty ? commit.sha : commit.title).lineLimit(1)
        HStack(spacing: Theme.Spacing.small) {
          Text(commit.shortSha).font(.caption.monospaced())
          if let author = commit.author { Text(author).lineLimit(1) }
          if let date = commit.date {
            Text(Theme.relativeDate(date, now: .now))
              .help(date.formatted(date: .abbreviated, time: .shortened))
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.small)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .font(.callout)
    .accessibilityIdentifier("pr-commit-\(commit.shortSha)")
  }

  private func message(_ text: String, failure: Bool = false) -> some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(failure ? AnyShapeStyle(Theme.failure) : AnyShapeStyle(.secondary))
      .padding(Theme.Spacing.medium)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The bar over one commit's patch: back to the list, its title and id, and the older and
/// newer commits.
struct PullRequestCommitBar: View {
  let state: PullRequestCommitBarState
  let actions: PullRequestChangesActions

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      if let back = actions.backToCommits {
        Button("Back", action: back).accessibilityLabel("Back to commits")
      }
      Text(state.title ?? "Commit").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        .help(state.title ?? "")
      Text(String(state.sha.prefix(7))).font(.caption.monospaced()).foregroundStyle(.secondary)
      Button {
        if let previous = state.previous { actions.openCommit?(previous) }
      } label: {
        Image(systemName: "chevron.up").accessibilityLabel("Previous commit")
      }
      .disabled(state.previous == nil)
      .help("Previous commit")
      Button {
        if let next = state.next { actions.openCommit?(next) }
      } label: {
        Image(systemName: "chevron.down").accessibilityLabel("Next commit")
      }
      .disabled(state.next == nil)
      .help("Next commit")
    }
    .buttonStyle(.borderless)
    .font(.callout)
    .padding(.horizontal, Theme.Spacing.small)
    .padding(.vertical, Theme.Spacing.extraSmall)
    .accessibilityIdentifier("pr-commit-bar")
  }
}

/// "Changes since": the PR base or one of its commits, newest first; a commit that heads
/// another PR (a stacked PR's parent) says so. The list reads when the picker opens.
struct PullRequestChangesSincePicker: View {
  let state: PullRequestChangesSinceState
  let actions: PullRequestChangesActions
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: Theme.Spacing.tiny) {
        Text(state.label).lineLimit(1)
        Image(systemName: "chevron.down").font(.caption2)
      }
    }
    .help("Changes since")
    .accessibilityLabel("Changes since")
    .accessibilityValue(state.label)
    .accessibilityIdentifier("pr-changes-since")
    .popover(isPresented: $isPresented) {
      options
        .frame(minWidth: 280, maxWidth: 420, maxHeight: 320)
        .presentationCompactAdaptation(.popover)
        .onAppear { actions.openSince?() }
    }
  }

  private var options: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        option(nil, title: Text("PR base (all changes)"))
        if let note = state.limitNote { caption(note) }
        if let error = state.error {
          caption("\(error) Open this list again to retry.", failure: true)
        }
        if state.isLoading, state.commits.isEmpty {
          HStack(spacing: Theme.Spacing.small) {
            ProgressView().controlSize(.small)
            Text("Loading commits\u{2026}")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(Theme.Spacing.small)
        }
        ForEach(state.commits) { commit in
          option(commit.sha, title: commitTitle(commit))
        }
      }
      .padding(.vertical, Theme.Spacing.extraSmall)
    }
  }

  private func commitTitle(_ commit: PullRequestCommitRow) -> some View {
    HStack(spacing: Theme.Spacing.small) {
      if let headOf = commit.headOf {
        Text(headOf)
          .font(.caption.weight(.medium))
          .foregroundStyle(.white)
          .padding(.horizontal, Theme.Spacing.extraSmall)
          .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
      }
      Text(commit.shortSha).font(.caption.monospaced()).foregroundStyle(.secondary)
      Text(commit.title.isEmpty ? commit.sha : commit.title).lineLimit(1)
    }
  }

  private func option(_ sha: String?, title: some View) -> some View {
    Button {
      actions.setSince?(sha)
      isPresented = false
    } label: {
      HStack(spacing: Theme.Spacing.small) {
        Image(systemName: "checkmark")
          .opacity(state.selected == sha ? 1 : 0)
          .accessibilityHidden(true)
        title.lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Theme.Spacing.small)
      .padding(.vertical, Theme.Spacing.extraSmall)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .font(.callout)
  }

  private func caption(_ text: String, failure: Bool = false) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(failure ? AnyShapeStyle(Theme.failure) : AnyShapeStyle(.secondary))
      .padding(.horizontal, Theme.Spacing.small)
      .padding(.vertical, Theme.Spacing.extraSmall)
  }
}
