import OmnigentPlatform
import SwiftUI

/// The Pull Requests tab: the session's linked PRs with Link and Refresh, or the one the user
/// opened (``PullRequestDetailView``).
struct PullRequestsPanel: View {
  let state: PullRequestsPanelState
  var extras = PullRequestPanelExtras()
  let open: (@MainActor (URL) -> Void)?
  let refresh: (@MainActor () -> Void)?

  @State private var linking = false

  private var actions: PullRequestPanelActions { extras.actions }

  var body: some View {
    Group {
      if let detail = extras.detail {
        PullRequestDetailView(
          content: detail, extras: extras, listCount: listCount, open: open)
      } else {
        VStack(spacing: 0) {
          if actions.link != nil || refresh != nil {
            toolbar
            Divider()
          }
          if linking, let link = actions.link {
            PullRequestLinkField(
              isBusy: extras.isBusy, link: link, close: { linking = false })
            Divider()
          }
          if let error = extras.error {
            PullRequestErrorBar(message: error, dismiss: actions.dismissError)
          }
          list
        }
      }
    }
    .task { refresh?() }
  }

  private var listCount: Int {
    if case .loaded(let pullRequests, _) = state { return pullRequests.count }
    return 0
  }

  private var toolbar: some View {
    HStack(spacing: Theme.Spacing.small) {
      Text(listCount == 1 ? "1 pull request" : "\(listCount) pull requests")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      if actions.link != nil {
        Button {
          linking.toggle()
        } label: {
          Label("Link a PR", systemImage: "plus")
        }
        .help("Link a pull request to this session")
        .accessibilityIdentifier("pr-link")
      }
      if let refresh {
        Button(action: refresh) {
          Image(systemName: "arrow.clockwise").accessibilityLabel("Refresh")
        }
        .help("Refresh")
      }
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.vertical, Theme.Spacing.small)
  }

  @ViewBuilder private var list: some View {
    switch state {
    case .loading:
      ProgressView("Loading pull requests\u{2026}")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .unsupported:
      ContentUnavailableView(
        "Pull Requests", systemImage: "arrow.triangle.pull",
        description: Text("This server doesn't track pull requests."))
    case .failed(let message):
      ContentUnavailableView {
        Label("Couldn't Load Pull Requests", systemImage: "exclamationmark.triangle")
      } description: {
        Text(message)
      } actions: {
        if let refresh { Button("Try Again", action: refresh) }
      }
    case .loaded(let pullRequests, let synced):
      if pullRequests.isEmpty {
        ContentUnavailableView {
          Label(
            synced ? "No pull requests" : "Looking for pull requests",
            systemImage: "arrow.triangle.pull")
        } description: {
          Text(
            synced
              ? "Pull requests created in this session appear here. You can also link an existing PR."
              : "The server hasn't read this session's pull requests from its host yet.")
        } actions: {
          if actions.link != nil, !linking { Button("Link a PR") { linking = true } }
        }
      } else {
        PullRequestList(pullRequests: pullRequests, open: open, actions: actions)
      }
    }
  }
}

/// Linked pull requests, newest first as the server orders them. Choosing one opens it in the
/// panel when the app can read it, otherwise its page.
struct PullRequestList: View {
  let pullRequests: [PullRequestSummary]
  let open: (@MainActor (URL) -> Void)?
  var actions = PullRequestPanelActions()

  var body: some View {
    if pullRequests.isEmpty {
      ContentUnavailableView(
        "No pull requests", systemImage: "arrow.triangle.pull",
        description: Text("Pull requests created or worked on in this session appear here."))
    } else {
      List(pullRequests) { request in
        Button {
          if let select = actions.select {
            select(request.url)
          } else if let url = URL(string: request.url) {
            open?(url)
          }
        } label: {
          row(request)
        }
        .buttonStyle(.plain)
        .help(request.url)
        .contextMenu { menu(request) }
        .accessibilityIdentifier("pr-\(request.id)")
      }
      .listStyle(.plain)
    }
  }

  private func row(_ request: PullRequestSummary) -> some View {
    HStack(alignment: .top, spacing: Theme.Spacing.small) {
      PullRequestStatusIcon(status: request.status)
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        Text(request.title).lineLimit(2)
        HStack(spacing: Theme.Spacing.small) {
          Text(request.status.title).foregroundStyle(PullRequestStatusIcon.color(request.status))
          Text("\(request.repo) #\(request.number)").foregroundStyle(.secondary)
        }
        .font(.caption)
        if let detail = request.detail {
          Text(detail).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private func menu(_ request: PullRequestSummary) -> some View {
    if let url = URL(string: request.url) {
      Button("Open in Browser", systemImage: "safari") { open?(url) }
      Button("Copy Link", systemImage: "link") { Pasteboard.copy(request.url) }
    }
    if let unlink = actions.unlink {
      Divider()
      Button("Unlink", systemImage: "minus.circle", role: .destructive) { unlink(request.url) }
    }
  }
}

/// A pull request's status as the web's icon set draws it.
struct PullRequestStatusIcon: View {
  let status: PullRequestSummary.Status

  var body: some View {
    Image(systemName: Self.symbol(status))
      .foregroundStyle(Self.color(status))
      .frame(width: 16)
      .accessibilityHidden(true)
  }

  static func symbol(_ status: PullRequestSummary.Status) -> String {
    switch status {
    case .merged: "arrow.triangle.merge"
    case .closed: "xmark.circle"
    case .conflicts: "arrow.left.arrow.right.circle"
    case .failing: "xmark.circle.fill"
    case .ready: "checkmark.circle.fill"
    case .running: "circle.dotted.circle"
    case .draft: "circle.dashed"
    case .open, .unknown: "arrow.triangle.pull"
    }
  }

  static func color(_ status: PullRequestSummary.Status) -> ThemeColor {
    switch status {
    case .ready, .open: .prGreen
    case .conflicts, .failing, .closed: .prRed
    case .running: .prAmber
    case .merged: .prPurple
    case .draft, .unknown: .secondary
    }
  }
}

/// The address field that links a PR; Escape or Cancel closes it.
struct PullRequestLinkField: View {
  let isBusy: Bool
  let link: @MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void
  let close: () -> Void

  @State private var address = ""
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      TextField(
        "Pull request URL", text: $address, prompt: Text("https://github.com/owner/repo/pull/123")
      )
      .textFieldStyle(.roundedBorder)
      .focused($focused)
      .onSubmit(submit)
      .onKeyPress(.escape) {
        close()
        return .handled
      }
      .accessibilityIdentifier("pr-link-url")
      Button("Link", action: submit)
        .disabled(isBusy || address.trimmingCharacters(in: .whitespaces).isEmpty)
      Button("Cancel", action: close)
    }
    .padding(Theme.Spacing.small)
    .onAppear { focused = true }
  }

  private func submit() {
    guard !isBusy else { return }
    link(address) { linked in
      if linked { close() }
    }
  }
}

/// A failed change, with Dismiss.
struct PullRequestErrorBar: View {
  let message: String
  let dismiss: (@MainActor () -> Void)?

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.small) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(Theme.failure)
        .accessibilityHidden(true)
      Text(message)
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let dismiss {
        Button(action: dismiss) {
          Image(systemName: "xmark").accessibilityLabel("Dismiss")
        }
        .buttonStyle(.borderless)
      }
    }
    .padding(Theme.Spacing.small)
    .background(Theme.failure.opacity(0.08))
    .accessibilityElement(children: .combine)
  }
}
