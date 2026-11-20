import SwiftUI

/// One session on the board, as the web's `SessionCard`: the state badge, title, state, working
/// directory, branch and PR. The session shown beside the board has an accent ring.
struct CanvasCardView: View {
  let card: CanvasCard
  var isSelected = false

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      HStack(spacing: Theme.Spacing.small) {
        badge
        Text(card.title).font(.headline).lineLimit(1)
          .help(card.title)
      }
      Text(card.state.label).font(.caption).foregroundStyle(.secondary)
      detail(card.workspace, systemImage: "folder")
      if let branch = card.branch { detail(branch, systemImage: "arrow.triangle.branch") }
      if let pullRequest = card.pullRequest { pullRequestLink(pullRequest) }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Theme.Spacing.large)
    .padding(.vertical, Theme.Spacing.medium)
    .frame(
      width: CanvasGeometry.cardWidth, height: CanvasGeometry.cardHeight, alignment: .topLeading
    )
    .cardSurface(cornerRadius: Theme.Radius.medium)
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: Theme.Radius.medium)
          .strokeBorder(Theme.accent, lineWidth: 2)
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
  }

  private func pullRequestLink(_ pullRequest: CanvasPullRequest) -> some View {
    Link(destination: pullRequest.url) {
      Label {
        Text(pullRequest.text).lineLimit(1)
      } icon: {
        Image(systemName: "arrow.triangle.pull").accessibilityHidden(true)
      }
      .labelStyle(.titleAndIcon)
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(Theme.link)
    .help(pullRequest.tooltip)
    .accessibilityLabel(pullRequest.accessibilityLabel)
    .accessibilityIdentifier("canvas-card-pull-request")
  }

  @ViewBuilder private var badge: some View {
    switch card.state {
    case .needsYou: NeedsYouCapsule(requests: card.requests)
    case .running: ProgressView().controlSize(.mini).accessibilityHidden(true)
    case .failed:
      Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.failure)
        .accessibilityHidden(true)
    case .unread:
      Circle().fill(Theme.unread).frame(width: 8, height: 8).accessibilityHidden(true)
    case .idle:
      Circle().fill(Theme.secondary).frame(width: 8, height: 8).accessibilityHidden(true)
    }
  }

  private func detail(_ text: String, systemImage: String) -> some View {
    Label {
      Text(text).lineLimit(1).truncationMode(.middle)
    } icon: {
      Image(systemName: systemImage).accessibilityHidden(true)
    }
    .font(.caption.monospaced()).foregroundStyle(.secondary)
    .labelStyle(.titleAndIcon)
    .help(text)
  }
}
