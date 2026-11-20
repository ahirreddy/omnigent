import SwiftUI

/// The PR's reviewers with their review states; when editable, a picker requests reviews, and
/// each row re-requests a review or withdraws a pending request, as the web's.
struct PullRequestReviewersSection: View {
  let reviewers: [PullRequestChip]
  /// Chip ids with a pending request.
  var requested: Set<String> = []
  /// The PR's author, left out of the picker.
  var author: String?
  let editable: Bool
  let extras: PullRequestPanelExtras

  @State private var picking = false

  private var actions: PullRequestPanelActions { extras.actions }
  private var canEdit: Bool { editable && actions.setReviewer != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      PullRequestSectionHeading(title: "Reviewers") {
        if canEdit {
          Button {
            actions.loadReviewers?()
            picking = true
          } label: {
            Image(systemName: "plus").accessibilityLabel("Request a review")
          }
          .buttonStyle(.borderless)
          .disabled(extras.isBusy)
          .help("Request a review")
          .popover(isPresented: $picking, arrowEdge: .bottom) {
            PullRequestReviewerPicker(
              choices: extras.reviewerChoices, requested: requested, author: author,
              truncated: extras.reviewersTruncated,
              toggle: { id, add in actions.setReviewer?(id, add) })
          }
        }
      }
      if reviewers.isEmpty {
        Text("No reviewers assigned.").font(.callout).foregroundStyle(.secondary)
      }
      ForEach(reviewers) { reviewer in
        row(reviewer)
      }
    }
  }

  private func row(_ reviewer: PullRequestChip) -> some View {
    let pending = requested.contains(reviewer.id)
    let subject = reviewer.id.hasPrefix("team:") ? "Team \(reviewer.title)" : reviewer.title
    return HStack(spacing: Theme.Spacing.small) {
      Image(systemName: reviewer.systemImage ?? "person")
        .foregroundStyle(.secondary)
        .frame(width: 16)
        .accessibilityHidden(true)
      Text(reviewer.title).lineLimit(1)
      Spacer(minLength: 0)
      if let detail = reviewer.detail {
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      if canEdit {
        Button {
          actions.setReviewer?(reviewer.id, !pending)
        } label: {
          Image(systemName: pending ? "xmark" : "arrow.clockwise")
            .accessibilityLabel(
              pending
                ? "Withdraw review request from \(subject)" : "Re-request review from \(subject)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(extras.isBusy)
        .help(pending ? "Withdraw review request" : "Re-request review")
      }
    }
    .accessibilityElement(children: .combine)
    .contextMenu {
      if canEdit {
        if pending {
          Button("Withdraw Review Request", role: .destructive) {
            actions.setReviewer?(reviewer.id, false)
          }
        } else {
          Button("Re-request Review") { actions.setReviewer?(reviewer.id, true) }
        }
      }
    }
  }
}

/// The PR's labels in their colors; when editable, a picker adds and removes them.
struct PullRequestLabelsSection: View {
  let labels: [PullRequestChip]
  let editable: Bool
  let extras: PullRequestPanelExtras

  @State private var picking = false

  private var actions: PullRequestPanelActions { extras.actions }
  private var canEdit: Bool { editable && actions.setLabel != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      PullRequestSectionHeading(title: "Labels") {
        if canEdit {
          Button {
            actions.loadLabels?()
            picking = true
          } label: {
            Image(systemName: "plus").accessibilityLabel("Edit labels")
          }
          .buttonStyle(.borderless)
          .disabled(extras.isBusy)
          .help("Edit labels")
          .popover(isPresented: $picking, arrowEdge: .bottom) {
            PullRequestChoiceList(
              title: "Labels", choices: extras.labelChoices, selected: Set(labels.map(\.id)),
              toggle: { name, add in actions.setLabel?(name, add) },
              truncatedNoun: extras.labelsTruncated ? "labels" : nil)
          }
        }
      }
      if labels.isEmpty {
        Text("None yet").font(.callout).foregroundStyle(.secondary)
      }
      FlowLayout(spacing: Theme.Spacing.extraSmall) {
        ForEach(labels) { label in
          PullRequestLabelChip(label: label)
            .contextMenu {
              if canEdit {
                Button("Remove Label", role: .destructive) { actions.setLabel?(label.id, false) }
              }
            }
        }
      }
    }
  }
}

/// A label as GitHub draws it: a capsule tinted by the label's color.
struct PullRequestLabelChip: View {
  let label: PullRequestChip

  var body: some View {
    let tint = label.color.map { Color(hex: $0) } ?? Color.secondary
    Text(label.title)
      .font(.caption.weight(.medium))
      .lineLimit(1)
      .padding(.horizontal, Theme.Spacing.small)
      .padding(.vertical, Theme.Spacing.tiny)
      .background(tint.opacity(0.18), in: Capsule())
      .overlay(Capsule().strokeBorder(tint.opacity(0.5)))
      .help(label.detail ?? label.title)
  }
}

/// A checklist of choices read on demand; toggling one adds or removes it.
struct PullRequestChoiceList: View {
  let title: String
  let choices: PullRequestChoices
  let selected: Set<String>
  let toggle: (String, Bool) -> Void
  /// What the list holds, when the provider had more than were read ("labels").
  var truncatedNoun: String?

  @State private var filter = ""

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text(title).font(.headline)
      switch choices {
      case .idle, .loading:
        ProgressView().frame(maxWidth: .infinity)
      case .failed(let message):
        Text(message).foregroundStyle(Theme.failure)
      case .loaded(let items):
        SearchField("Filter", text: $filter)
        List(shown(items)) { item in
          Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: { toggle(item.id, $0) })) {
            VStack(alignment: .leading, spacing: 0) {
              Text(item.title)
              if let detail = item.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
        .listStyle(.plain)
        .frame(minHeight: 160)
        if let truncatedNoun {
          Text("Showing the first \(items.count) \(truncatedNoun).")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .padding(Theme.Spacing.medium)
    .frame(width: 280, height: 320, alignment: .top)
  }

  private func shown(_ items: [PullRequestChip]) -> [PullRequestChip] {
    let query = filter.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return items }
    return items.filter {
      $0.title.localizedCaseInsensitiveContains(query)
        || ($0.detail?.localizedCaseInsensitiveContains(query) ?? false)
    }
  }
}
