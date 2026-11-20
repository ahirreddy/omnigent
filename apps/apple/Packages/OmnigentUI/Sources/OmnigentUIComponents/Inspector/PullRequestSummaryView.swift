import SwiftUI

/// The Summary tab: reviewers beside labels, then CI checks with the merge control, then the
/// description, as the web's PR panel orders them.
struct PullRequestSummaryView: View {
  let state: PullRequestDetailViewState
  let extras: PullRequestPanelExtras
  let open: (@MainActor (URL) -> Void)?
  /// The description being edited, kept by the detail view across tab switches.
  var draft: Binding<PullRequestDescriptionDraft?> = .constant(nil)

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        if state.showsReviewers || state.showsLabels {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Spacing.large) { people }
            VStack(alignment: .leading, spacing: Theme.Spacing.large) { people }
          }
          Divider()
        }
        if showsChecks {
          PullRequestChecksSection(groups: state.checks, note: state.checksNote, open: open)
        }
        if let merge = state.merge {
          PullRequestMergeSection(state: state, merge: merge, extras: extras)
        }
        if showsChecks || state.merge != nil { Divider() }
        PullRequestDescriptionSection(state: state, extras: extras, draft: draft)
      }
      .padding(Theme.Spacing.medium)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var showsChecks: Bool { !state.checks.isEmpty || state.checksNote != nil }

  @ViewBuilder private var people: some View {
    if state.showsReviewers {
      PullRequestReviewersSection(
        reviewers: state.reviewers, requested: state.requestedReviewers, author: state.author,
        editable: state.canEditReviewers, extras: extras
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    if state.showsLabels {
      PullRequestLabelsSection(
        labels: state.labels, editable: state.canEditLabels, extras: extras
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// A small uppercase heading, with an optional trailing control.
struct PullRequestSectionHeading<Trailing: View>: View {
  let title: String
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack {
      Text(title.uppercased())
        .font(Theme.Typography.section)
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 0)
      trailing
    }
  }
}

/// CI checks per bucket; each bucket expands to its checks, which open their runs.
struct PullRequestChecksSection: View {
  let groups: [PullRequestCheckGroup]
  let note: String?
  let open: (@MainActor (URL) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      PullRequestSectionHeading(title: "Checks") { EmptyView() }
      if let note {
        Text(note).font(.callout).foregroundStyle(.secondary)
      }
      ForEach(groups) { group in
        DisclosureGroup {
          ForEach(group.runs, id: \.self) { run in
            Button {
              if let url = run.url { open?(url) }
            } label: {
              Text(run.name).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(run.url == nil)
            .help(run.url?.absoluteString ?? run.name)
          }
        } label: {
          Label("\(group.count) \(group.bucket.rawValue)", systemImage: Self.symbol(group.bucket))
            .foregroundStyle(Self.color(group.bucket))
        }
      }
    }
  }

  static func symbol(_ bucket: PullRequestCheckGroup.Bucket) -> String {
    switch bucket {
    case .passed: "checkmark.circle.fill"
    case .pending: "circle.dotted.circle"
    case .failed: "xmark.circle.fill"
    case .cancelled: "nosign"
    case .skipped: "minus.circle"
    }
  }

  static func color(_ bucket: PullRequestCheckGroup.Bucket) -> ThemeColor {
    switch bucket {
    case .passed: .prGreen
    case .pending: .prAmber
    case .failed: .prRed
    case .cancelled, .skipped: .secondary
    }
  }
}

/// The merge control: Merge with a method chosen in a confirmation, why it cannot merge yet,
/// or auto-merge with Disable.
struct PullRequestMergeSection: View {
  let state: PullRequestDetailViewState
  let merge: PullRequestMergeState
  let extras: PullRequestPanelExtras

  @State private var confirming = false

  private var actions: PullRequestPanelActions { extras.actions }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      switch merge {
      case .autoMerge:
        Text("This pull request will merge automatically when all requirements are met.")
          .font(.callout)
        if let disable = actions.disableAutoMerge {
          Button("Disable Auto-Merge", action: disable).disabled(extras.isBusy)
        }
      case .checking(let hint):
        HStack(spacing: Theme.Spacing.small) {
          ProgressView().controlSize(.small)
          Text(hint).font(.callout).foregroundStyle(.secondary)
        }
      case .blocked(let hint):
        mergeButton.disabled(true)
        Text(hint).font(.callout).foregroundStyle(.secondary)
      case .ready(let hint):
        if !state.mergeAccounts.isEmpty, let setAccount = actions.setAccount {
          // Reading a PR doesn't mean an account may merge it, so the merge picks its own.
          PullRequestAccountPicker(
            title: "Merge as", accounts: state.mergeAccounts, isBusy: extras.isBusy,
            choose: setAccount)
        }
        mergeButton.disabled(extras.isBusy || actions.merge == nil || accountUnknown)
        if let hint { Text(hint).font(.callout).foregroundStyle(.secondary) }
      }
      if confirming, case .failed(let message) = extras.mergeMethods {
        Text(message).font(.callout).foregroundStyle(Theme.failure)
      }
    }
    .confirmationDialog(
      "Merge pull request \(state.numberLabel)?", isPresented: dialogPresented,
      titleVisibility: .visible
    ) {
      ForEach(methods) { method in
        Button(method.title) {
          if let account = mergeAccount, let mergeAs = actions.mergeAs {
            mergeAs(method.id, account)
          } else {
            actions.merge?(method.id)
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "\u{201C}\(state.title)\u{201D} will be merged\(mergeAccount.map { " as \($0)" } ?? ""). "
          + "This can't be undone.")
    }
  }

  /// The account the merge runs as, when the merge picks one.
  private var mergeAccount: String? {
    state.mergeAccounts.isEmpty ? nil : state.mergeAccounts.first(where: \.selected)?.login
  }

  /// The merge picks an account, but none is chosen yet.
  private var accountUnknown: Bool { !state.mergeAccounts.isEmpty && mergeAccount == nil }

  private var methods: [PullRequestChip] {
    if case .loaded(let methods) = extras.mergeMethods { return methods }
    return []
  }

  /// Shown once the methods are read, so the dialog never opens empty.
  private var dialogPresented: Binding<Bool> {
    Binding(
      get: { confirming && !methods.isEmpty },
      set: { if !$0 { confirming = false } })
  }

  private var mergeButton: some View {
    HStack(spacing: Theme.Spacing.small) {
      Button {
        actions.loadMergeMethods?()
        confirming = true
      } label: {
        Label("Merge\u{2026}", systemImage: "arrow.triangle.merge")
      }
      .buttonStyle(.borderedProminent)
      .tint(PullRequestStatusIcon.color(.ready))
      .accessibilityIdentifier("pr-merge")
      if confirming, extras.mergeMethods == .loading || extras.isBusy {
        ProgressView().controlSize(.small)
      }
    }
  }
}
