import OmnigentPlatform
import SwiftUI

/// The PR the user opened from the Pull Requests tab, as the web's PR panel lays it out: back to
/// the list, the repository and branches, the title with its status, then Summary, Comments and
/// Changes. With the host offline, the PR as the server stored it.
struct PullRequestDetailView: View {
  let content: PullRequestDetailContent
  let extras: PullRequestPanelExtras
  let listCount: Int
  let open: (@MainActor (URL) -> Void)?

  @State private var tab: PullRequestDetailTab = .summary
  @State private var linking = false
  @State private var descriptionDraft: PullRequestDescriptionDraft?
  @State private var commentDraft = ""

  private var actions: PullRequestPanelActions { extras.actions }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      if linking, let link = actions.link {
        PullRequestLinkField(isBusy: extras.isBusy, link: link, close: { linking = false })
        Divider()
      }
      if let error = extras.error {
        PullRequestErrorBar(message: error, dismiss: actions.dismissError)
      }
      switch content {
      case .loading:
        LoadingCaption(title: "Loading pull request\u{2026}")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        ContentUnavailableView {
          Label("Couldn't Load the Pull Request", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          if let refresh = actions.refresh { Button("Try Again", action: refresh) }
        }
      case .unavailable(let title, let message, let systemImage):
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
      case .stored(let state):
        PullRequestStoredView(state: state, open: open)
      case .ready(let state):
        ready(state)
      }
    }
  }

  private var toolbar: some View {
    HStack(spacing: Theme.Spacing.small) {
      // One PR has no list to go back to, as on the web.
      if let showList = actions.showList, listCount > 1 {
        Button(action: showList) {
          Label("All pull requests (\(listCount))", systemImage: "chevron.left")
        }
        .accessibilityIdentifier("pr-back")
      }
      Spacer(minLength: 0)
      if let refresh = actions.refresh {
        Button(action: refresh) {
          Image(systemName: "arrow.clockwise").accessibilityLabel("Refresh")
        }
        .help("Refresh")
      }
      if actions.link != nil {
        Button {
          linking.toggle()
        } label: {
          Image(systemName: "plus").accessibilityLabel("Link a PR")
        }
        .help("Link a pull request to this session")
        .accessibilityIdentifier("pr-link")
      }
      if let link = content.link {
        if let url = URL(string: link.url) {
          Button {
            open?(url)
          } label: {
            Image(systemName: "safari").accessibilityLabel("Open on \(link.providerName)")
          }
          .help("Open on \(link.providerName)")
        }
        if let unlink = actions.unlink {
          Button {
            unlink(link.url)
          } label: {
            Image(systemName: "minus.circle").accessibilityLabel("Unlink PR")
          }
          .disabled(extras.isBusy)
          .help("Unlink this pull request from the session")
        }
      }
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.vertical, Theme.Spacing.small)
  }

  private func ready(_ state: PullRequestDetailViewState) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      PullRequestDetailHeader(state: state, extras: extras)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
      Picker("Pull request", selection: $tab) {
        ForEach(PullRequestDetailTab.allCases) { item in
          Text(item.title(state)).tag(item)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.bottom, Theme.Spacing.small)
      Divider()
      switch tab {
      case .summary:
        PullRequestSummaryView(
          state: state, extras: extras, open: open, draft: $descriptionDraft)
      case .comments:
        PullRequestCommentsView(
          state: state, extras: extras, open: open, keptDraft: $commentDraft)
      case .changes:
        if let changes = extras.changes {
          changes
        } else {
          ContentUnavailableView(
            "Changes", systemImage: "plus.forwardslash.minus",
            description: Text("The pull request's changes appear here."))
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onChange(of: state.url) {
      descriptionDraft = nil
      commentDraft = ""
    }
    .onChange(of: extras.opensChanges, initial: true) { _, opens in
      guard opens else { return }
      tab = .changes
      actions.changesOpened?()
    }
  }
}

/// The open PR's tabs.
enum PullRequestDetailTab: String, CaseIterable, Identifiable {
  case summary, comments, changes

  var id: String { rawValue }

  func title(_ state: PullRequestDetailViewState) -> String {
    switch self {
    case .summary: "Summary"
    case .comments:
      state.comments.isEmpty
        ? "Comments" : "Comments \(state.comments.count)\(state.commentsPartial ? "+" : "")"
    case .changes: state.fileCount.map { "Changes \($0)" } ?? "Changes"
    }
  }
}

/// The PR as the server stored it while the host is offline: repository, title and number
/// linking out, the stored state, and what loads the rest.
private struct PullRequestStoredView: View {
  let state: PullRequestStoredViewState
  let open: (@MainActor (URL) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text(state.repository)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
        Button {
          if let url = URL(string: state.url) { open?(url) }
        } label: {
          Text(state.title).font(.headline).lineLimit(3).multilineTextAlignment(.leading)
          Text(state.numberLabel).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Open on \(state.providerName)")
        Spacer(minLength: 0)
        PullRequestStatusChip(status: state.status)
      }
      Divider()
      Label(state.hint, systemImage: "server.rack")
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("pr-stored-hint")
    }
    .padding(Theme.Spacing.medium)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// The status as a tinted capsule.
struct PullRequestStatusChip: View {
  let status: PullRequestSummary.Status

  var body: some View {
    Label(status.title, systemImage: PullRequestStatusIcon.symbol(status))
      .font(.caption.weight(.medium))
      .foregroundStyle(PullRequestStatusIcon.color(status))
      .padding(.horizontal, Theme.Spacing.small)
      .padding(.vertical, Theme.Spacing.tiny)
      .background(PullRequestStatusIcon.color(status).opacity(0.12), in: Capsule())
      .fixedSize()
  }
}
