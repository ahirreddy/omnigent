import SwiftUI

/// The tray's pull request link, as the web's composer shows it: "#123" or "N PRs" in the color
/// of the PR that most needs the user, opening the Pull Requests tab. Hovering shows each linked
/// PR with its status.
struct ComposerPullRequestChip: View {
  let label: String
  let status: PullRequestSummary.Status?
  let preview: [PullRequestSummary]
  let open: (@MainActor () -> Void)?

  @State private var hovering = false
  @State private var showsPreview = false

  var body: some View {
    let status = status ?? .unknown
    Button {
      showsPreview = false
      open?()
    } label: {
      Label(label, systemImage: PullRequestStatusIcon.symbol(status))
        .foregroundStyle(PullRequestStatusIcon.color(status))
        .monospacedDigit()
        .contentShape(Rectangle())
    }
    .disabled(open == nil)
    .help(preview.isEmpty ? "Pull requests: \(label)" : "")
    .accessibilityLabel("Pull requests, \(label)")
    .accessibilityValue(status.title)
    .accessibilityHint("Shows the Pull Requests tab")
    .accessibilityIdentifier("composer-pull-requests")
    .onHover { inside in
      hovering = inside
      guard !preview.isEmpty else { return }
      if inside {
        Task {
          // A short delay, so passing over the chip does not open the preview.
          try? await Task.sleep(for: .milliseconds(350))
          if hovering { showsPreview = true }
        }
      } else {
        showsPreview = false
      }
    }
    .popover(isPresented: $showsPreview, arrowEdge: .top) {
      ComposerPullRequestPreview(pullRequests: preview)
    }
  }
}

/// The hover preview: each linked PR's repository, number, status and title.
struct ComposerPullRequestPreview: View {
  let pullRequests: [PullRequestSummary]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Pull requests")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          ForEach(pullRequests) { request in
            HStack(alignment: .top, spacing: Theme.Spacing.small) {
              PullRequestStatusIcon(status: request.status)
              VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
                HStack(alignment: .firstTextBaseline) {
                  Text("\(request.repo) #\(request.number)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                  Spacer(minLength: Theme.Spacing.small)
                  Text(request.status.title)
                    .font(.caption)
                    .foregroundStyle(PullRequestStatusIcon.color(request.status))
                }
                Text(request.title).font(.callout.weight(.medium)).lineLimit(1)
              }
            }
            .accessibilityElement(children: .combine)
          }
        }
        .padding(Theme.Spacing.medium)
      }
      .frame(maxHeight: 320)
    }
    .frame(width: 360)
  }
}
