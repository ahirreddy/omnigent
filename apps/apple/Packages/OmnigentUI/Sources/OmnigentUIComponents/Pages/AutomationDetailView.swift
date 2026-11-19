import OmnigentPlatform
public import SwiftUI

/// One automation's page: name and actions, the active switch with its schedule, the session
/// it starts from, the prompt, its saved configuration, and its run history. A shared one is
/// read-only: its actions show disabled and say why.
public struct AutomationDetailView: View {
  private let state: AutomationDetailState
  private let actions: AutomationDetailActions
  @State private var confirmingDelete = false
  @State private var showsConfiguration = true

  /// Creates the page.
  public init(state: AutomationDetailState, actions: AutomationDetailActions) {
    self.state = state
    self.actions = actions
  }

  /// The page.
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        if let back = actions.back {
          Button("Automations", systemImage: "chevron.left", action: back)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("automation-detail-back")
        }
        header
        statusLine
        if let error = state.actionError { errorBanner(error) }
        if let startsFrom = state.startsFrom { startsFromSection(startsFrom) }
        section(state.promptTitle) {
          Text(state.prompt.isEmpty && state.startsFrom != nil ? "None" : state.prompt)
            .textSelection(.enabled)
            .accessibilityIdentifier("automation-detail-prompt")
        }
        configuration
        Divider()
        section("Runs") { runs }
      }
      .padding(Theme.Spacing.gutter)
      .frame(maxWidth: Theme.inboxWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .themeCanvas()
    .navigationTitle(state.name)
    .confirmationDialog("Delete this automation?", isPresented: $confirmingDelete) {
      Button("Delete", role: .destructive) { actions.delete?() }
    } message: {
      Text("\u{201C}\(state.name)\u{201D} stops running. Sessions it started stay.")
    }
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        Text(state.name).font(.largeTitle.weight(.semibold))
          .accessibilityIdentifier("automation-detail-title")
        if let owner = state.sharedBy {
          Text("Shared by \(owner)").foregroundStyle(.secondary)
            .accessibilityIdentifier("automation-detail-owner")
        }
      }
      Spacer()
      shareButton
      if let edit = actions.edit {
        ownerOnly(OwnerOnlyReason.edit) {
          Button("Edit automation", systemImage: "pencil", action: edit)
            .labelStyle(.iconOnly).disabled(state.isBusy || state.isReadOnly)
        }
        .accessibilityIdentifier("automation-detail-edit")
      }
      if actions.delete != nil {
        ownerOnly(OwnerOnlyReason.delete) {
          Button("Delete automation", systemImage: "trash") { confirmingDelete = true }
            .labelStyle(.iconOnly).disabled(state.isBusy || state.isReadOnly)
        }
        .accessibilityIdentifier("automation-detail-delete")
      }
      if let runNow = actions.runNow, !state.isTrigger {
        ownerOnly(OwnerOnlyReason.runNow) {
          Button(action: runNow) {
            if state.isBusy {
              Label {
                Text("In progress")
              } icon: {
                ProgressView().controlSize(.small)
              }
            } else {
              Label("Run now", systemImage: "play.fill")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(state.isBusy || state.isReadOnly)
        }
        .accessibilityIdentifier("automation-detail-run-now")
      }
    }
  }

  @ViewBuilder private var shareButton: some View {
    if state.isReadOnly {
      Button("Share automation", systemImage: "square.and.arrow.up") {}
        .labelStyle(.iconOnly).disabled(true).help(OwnerOnlyReason.share)
        .accessibilityIdentifier("automation-detail-share")
    } else if state.canShare {
      if let reason = state.shareDisabledReason {
        Button("Share automation", systemImage: "square.and.arrow.up") {}
          .labelStyle(.iconOnly).disabled(true).help(reason)
          .accessibilityIdentifier("automation-detail-share")
      } else if let share = actions.share {
        Button("Share automation", systemImage: "square.and.arrow.up", action: share)
          .labelStyle(.iconOnly)
          .accessibilityIdentifier("automation-detail-share")
      }
    }
  }

  /// A control a viewer sees disabled, with why.
  @ViewBuilder private func ownerOnly(_ reason: String, @ViewBuilder content: () -> some View)
    -> some View
  {
    if state.isReadOnly { content().help(reason) } else { content() }
  }

  private var statusLine: some View {
    HStack(spacing: Theme.Spacing.small) {
      if let setPaused = actions.setPaused {
        Toggle(
          state.isPaused ? "Resume automation" : "Pause automation",
          isOn: Binding(get: { !state.isPaused }, set: { setPaused(!$0) })
        )
        .toggleStyle(.switch).labelsHidden().controlSize(.small)
        .disabled(state.isBusy || state.isReadOnly)
        .help(
          state.isReadOnly ? (state.isPaused ? OwnerOnlyReason.resume : OwnerOnlyReason.pause) : ""
        )
        .accessibilityIdentifier("automation-detail-active")
      }
      Text(state.isPaused ? "Paused" : "Active")
        .font(.caption.weight(.medium))
        .foregroundStyle(state.isPaused ? Color.secondary : Color.green)
        .padding(.horizontal, Theme.Spacing.small).padding(.vertical, Theme.Spacing.tiny)
        .background(
          Capsule().fill(
            state.isPaused ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.green.opacity(0.15))))
      Text(state.scheduleText).foregroundStyle(.secondary)
        .accessibilityIdentifier("automation-detail-schedule")
    }
    .font(.callout)
  }

  private func startsFromSection(_ title: String) -> some View {
    section("Starts from") {
      if let id = state.startsFromSessionID, let open = actions.openSession {
        Button(title) { open(id) }
          #if os(macOS)
            .buttonStyle(.link)
          #else
            .buttonStyle(.borderless)
          #endif
          .accessibilityIdentifier("automation-detail-starts-from")
        Text("Each run starts with a copy of this session\u{2019}s history.")
          .font(.callout).foregroundStyle(.secondary)
      } else {
        Text(title).foregroundStyle(.secondary)
          .accessibilityIdentifier("automation-detail-starts-from")
      }
    }
  }

  private var configuration: some View {
    DisclosureGroup(isExpanded: $showsConfiguration) {
      VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 220), alignment: .topLeading)],
          alignment: .leading, spacing: Theme.Spacing.medium
        ) {
          ForEach(state.configuration) { field in
            VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
              Text(field.label.uppercased()).font(.caption).foregroundStyle(.secondary)
              Text(field.value).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("automation-detail-config-\(field.label)")
          }
        }
        if let note = state.configurationNote {
          Text(note).font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(.top, Theme.Spacing.small)
    } label: {
      Text("Configuration").font(.callout.weight(.medium)).foregroundStyle(.secondary)
    }
    .accessibilityIdentifier("automation-detail-configuration")
  }

  @ViewBuilder private var runs: some View {
    if state.showsSessionCostNote {
      Text(
        "Session cost is each session\u{2019}s current recorded total. Runs sharing a session show the same total. Separate sub-agent sessions are excluded."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
    if state.isLoadingRuns {
      LoadingCaption(title: "Loading runs\u{2026}").frame(maxWidth: .infinity).padding()
    } else if let error = state.runsError {
      HStack {
        Text("Couldn\u{2019}t load run history.").foregroundStyle(.secondary)
        Text(error).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
        Spacer()
        if let retry = actions.retry { Button("Retry", action: retry) }
      }
    } else if state.runs.isEmpty {
      Text("No runs yet.").foregroundStyle(.secondary)
        .accessibilityIdentifier("automation-detail-runs-empty")
    } else {
      LazyVStack(spacing: Theme.Spacing.extraSmall) {
        ForEach(state.runs) { run in
          AutomationRunRowView(
            run: run, open: openAction(run), openPullRequest: actions.openPullRequest)
        }
      }
      .accessibilityIdentifier("automation-detail-runs")
    }
  }

  private func openAction(_ run: AutomationRunRow) -> (@MainActor () -> Void)? {
    guard let id = run.sessionID, let open = actions.openSession else { return nil }
    return { open(id) }
  }

  private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
      content()
    }
  }

  private func errorBanner(_ message: String) -> some View {
    HStack {
      Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
      Spacer()
      if let dismiss = actions.dismissError { Button("Dismiss", action: dismiss) }
    }
    .font(.callout)
    .padding(Theme.Spacing.medium)
    .cardSurface(cornerRadius: Theme.Radius.medium)
  }
}

/// One run: its status icon, when it fired, how long it took, its session's cost, what it is
/// doing or waiting on, why it failed, and the PRs it made. A run with a session opens it.
struct AutomationRunRowView: View {
  let run: AutomationRunRow
  let open: (@MainActor () -> Void)?
  var openPullRequest: (@MainActor (URL) -> Void)?
  @State private var isHovered = false

  var body: some View {
    let row = HStack(
      alignment: run.failureReason == nil ? .center : .top, spacing: Theme.Spacing.medium
    ) {
      indicator.frame(width: 20)
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
          Text(run.timestamp)
          if let duration = run.duration {
            Text(duration).font(.caption).foregroundStyle(.secondary)
          }
          if let cost = run.sessionCost {
            Text(cost).font(.caption).foregroundStyle(.secondary)
              .accessibilityIdentifier("automation-run-cost-\(run.id)")
          }
          if let label = run.statusLabel, !run.needsApproval {
            Text(label).font(.caption).foregroundStyle(.secondary)
          }
        }
        if run.needsApproval {
          Text("Session needs approval \u{00B7} Open to review")
            .font(.caption).foregroundStyle(.orange)
            .accessibilityIdentifier("automation-run-approval-\(run.id)")
        }
        if let reason = run.failureReason {
          Text(failureText(reason)).font(.caption).foregroundStyle(.secondary)
          if let detail = run.errorDetail {
            Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
              .accessibilityIdentifier("automation-run-detail-\(run.id)")
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Theme.Spacing.small).padding(.vertical, Theme.Spacing.small)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.small)
        .fill(isHovered && open != nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
    )
    .contentShape(Rectangle())
    .accessibilityIdentifier("automation-run-\(run.id)")
    HStack(alignment: .top, spacing: Theme.Spacing.small) {
      if let open {
        Button(action: open) { row }.buttonStyle(.plain).onHover { isHovered = $0 }
      } else {
        row
      }
      if let summary = run.pullRequestSummary, !run.pullRequests.isEmpty {
        pullRequests(summary).padding(.top, Theme.Spacing.small)
      }
    }
  }

  /// The run's PRs as one line that opens the list, as the web's `RunPullRequests`.
  private func pullRequests(_ summary: String) -> some View {
    Menu {
      ForEach(run.pullRequests) { pullRequest in
        Button {
          openPullRequest?(pullRequest.url)
        } label: {
          Text("\(pullRequest.number) \(pullRequest.title)")
          Text(
            "\(pullRequest.status) \u{00B7} \(pullRequest.repository) \u{00B7} \(pullRequest.origin)"
          )
        }
      }
    } label: {
      Text(summary).font(.caption).underline()
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("\(summary). Show pull requests")
    .accessibilityIdentifier("automation-run-prs-\(run.id)")
  }

  private func failureText(_ reason: String) -> AttributedString {
    guard let stage = run.failureStage else { return AttributedString(reason) }
    var text = AttributedString(stage)
    text.font = .caption.weight(.medium)
    return text + AttributedString(" \u{00B7} \(reason)")
  }

  @ViewBuilder private var indicator: some View {
    switch run.indicator {
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        .help("Failed").accessibilityLabel("Failed")
    case .skipped:
      Image(systemName: "calendar.badge.minus").foregroundStyle(.secondary)
        .help("Skipped").accessibilityLabel("Skipped")
    case .inFlight:
      ProgressView().controlSize(.mini)
    case .sessionRunning:
      ProgressView().controlSize(.mini).help("Session still running")
    case .unread:
      Circle().fill(Theme.accent).frame(width: 8, height: 8)
        .help("Unread").accessibilityLabel("Unread")
    case .completed:
      Circle().fill(.tertiary).frame(width: 8, height: 8)
        .help("Completed").accessibilityLabel("Completed")
    case .queued:
      Circle().fill(.tertiary).frame(width: 8, height: 8).accessibilityLabel("Queued")
    }
  }
}
