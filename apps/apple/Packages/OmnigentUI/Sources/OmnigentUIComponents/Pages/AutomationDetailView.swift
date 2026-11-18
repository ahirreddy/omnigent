import OmnigentPlatform
public import SwiftUI

/// One automation's page, laid out as the web's `/tasks/:id`: the way back, the name with Share,
/// Edit, Delete and Run now, the active switch with its state and schedule, the session it
/// starts from, the prompt, its saved configuration (folded away), and its run history. A
/// shared one is read-only: its actions show disabled and say why.
public struct AutomationDetailView: View {
  private let state: AutomationDetailState
  private let actions: AutomationDetailActions
  @State private var confirmingDelete = false
  @State private var showsConfiguration = false
  @Environment(\.layoutWidth) private var layoutWidth

  /// Creates the page.
  public init(state: AutomationDetailState, actions: AutomationDetailActions) {
    self.state = state
    self.actions = actions
  }

  /// The page.
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if let back = actions.back {
          Button(action: back) {
            Label("Automations", systemImage: "chevron.left")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("automation-detail-back")
          .padding(.bottom, Theme.Spacing.large)
        }
        header
        statusLine.padding(.top, Theme.Spacing.medium)
        if let error = state.actionError {
          AutomationErrorBanner(
            message: error, actionTitle: actions.dismissError == nil ? nil : "Dismiss",
            action: actions.dismissError
          )
          .padding(.top, Theme.Spacing.large)
        }
        if let startsFrom = state.startsFrom { startsFromSection(startsFrom) }
        section(state.promptTitle) {
          Text(state.prompt.isEmpty && state.startsFrom != nil ? "None" : state.prompt)
            .foregroundStyle(.primary.opacity(0.9))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("automation-detail-prompt")
        }
        configuration.padding(.top, Theme.Spacing.extraLarge)
        Divider().padding(.vertical, Theme.Spacing.extraLarge)
        Text("Runs").font(AutomationStyle.sectionLabel).foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
          .padding(.bottom, Theme.Spacing.small)
        runs
      }
      .padding(.horizontal, AutomationStyle.gutter(layoutWidth))
      .padding(.vertical, Theme.Spacing.extraLarge)
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
    HStack(alignment: .top, spacing: Theme.Spacing.large) {
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        Text(state.name).font(AutomationStyle.pageTitle.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("automation-detail-title")
        if let owner = state.sharedBy {
          Text("Shared by \(owner)").font(.callout).foregroundStyle(.secondary)
            .accessibilityIdentifier("automation-detail-owner")
        }
      }
      Spacer(minLength: 0)
      HStack(spacing: Theme.Spacing.small) {
        shareButton
        if let edit = actions.edit {
          ownerOnly(OwnerOnlyReason.edit) {
            iconButton("Edit automation", systemImage: "pencil", action: edit)
              .disabled(state.isBusy || state.isReadOnly)
          }
          .accessibilityIdentifier("automation-detail-edit")
        }
        if actions.delete != nil {
          ownerOnly(OwnerOnlyReason.delete) {
            iconButton("Delete automation", systemImage: "trash") { confirmingDelete = true }
              .disabled(state.isBusy || state.isReadOnly)
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
            .fixedSize()
            .disabled(state.isBusy || state.isReadOnly)
          }
          .accessibilityIdentifier("automation-detail-run-now")
        }
      }
    }
  }

  /// A ghost icon button, as the web's header actions.
  private func iconButton(
    _ title: String, systemImage: String, action: @escaping @MainActor () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .frame(width: Theme.Control.target, height: Theme.Control.target)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .hoverHighlight()
    .help(title)
    .accessibilityLabel(title)
  }

  @ViewBuilder private var shareButton: some View {
    if state.isReadOnly {
      iconButton("Share automation", systemImage: "square.and.arrow.up") {}
        .disabled(true).help(OwnerOnlyReason.share)
        .accessibilityIdentifier("automation-detail-share")
    } else if state.canShare {
      if let reason = state.shareDisabledReason {
        iconButton("Share automation", systemImage: "square.and.arrow.up") {}
          .disabled(true).help(reason)
          .accessibilityIdentifier("automation-detail-share")
      } else if let share = actions.share {
        iconButton("Share automation", systemImage: "square.and.arrow.up", action: share)
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

  /// The active switch (on is active), the state pill, and the schedule with its next run.
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
        .foregroundStyle(state.isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.success))
        .padding(.horizontal, Theme.Spacing.small).padding(.vertical, Theme.Spacing.tiny)
        .background(
          Capsule().fill(
            state.isPaused
              ? AnyShapeStyle(AutomationStyle.mutedFill)
              : AnyShapeStyle(Theme.success.opacity(0.15))
          )
        )
        .fixedSize()
        .accessibilityIdentifier("automation-detail-state")
      Text(state.scheduleText).foregroundStyle(.secondary)
        .accessibilityIdentifier("automation-detail-schedule")
    }
    .font(.callout)
  }
}

/// The page's sections: the session it starts from, the configuration and the runs.
extension AutomationDetailView {
  private func startsFromSection(_ title: String) -> some View {
    section("Starts from") {
      if let id = state.startsFromSessionID, let open = actions.openSession {
        Button(title) { open(id) }.buttonStyle(.link)
          .accessibilityIdentifier("automation-detail-starts-from")
        Text("Each run starts with a copy of this session\u{2019}s history.")
          .font(.callout).foregroundStyle(.secondary)
          .padding(.top, Theme.Spacing.extraSmall)
      } else {
        Text(title).font(.callout).foregroundStyle(.secondary)
          .accessibilityIdentifier("automation-detail-starts-from")
      }
    }
  }

  /// The saved launch settings, folded away until asked for, as the web's Configuration.
  private var configuration: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Button {
        withAnimation(Theme.Motion.disclosure) { showsConfiguration.toggle() }
      } label: {
        HStack(spacing: Theme.Spacing.extraSmall) {
          Image(systemName: "chevron.down")
            .font(.caption.weight(.semibold))
            .rotationEffect(.degrees(showsConfiguration ? 0 : -90))
          Text("Configuration")
        }
        .font(AutomationStyle.sectionLabel)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(.isHeader)
      .accessibilityValue(showsConfiguration ? "Expanded" : "Collapsed")
      .accessibilityIdentifier("automation-detail-configuration")
      if showsConfiguration {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
          LazyVGrid(
            columns: Array(
              repeating: GridItem(
                .flexible(), spacing: Theme.Spacing.large, alignment: .topLeading),
              count: layoutWidth == .compact ? 1 : 2),
            alignment: .leading, spacing: Theme.Spacing.large
          ) {
            ForEach(state.configuration) { field in
              VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
                Text(field.label.uppercased()).font(.callout).tracking(0.5)
                  .foregroundStyle(.secondary)
                Text(field.value).textSelection(.enabled)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityElement(children: .combine)
              .accessibilityIdentifier("automation-detail-config-\(field.label)")
            }
          }
          if let note = state.configurationNote {
            Text(note).font(.callout).foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  @ViewBuilder private var runs: some View {
    if state.showsSessionCostNote {
      Text(
        "Session cost is each session\u{2019}s current recorded total. Runs sharing a session show the same total. Separate sub-agent sessions are excluded."
      )
      .font(.callout).foregroundStyle(.secondary)
      .padding(.bottom, Theme.Spacing.small)
    }
    if state.isLoadingRuns {
      AutomationLoadingRow(title: "Loading runs\u{2026}", verticalPadding: Theme.Spacing.extraLarge)
    } else if let error = state.runsError {
      HStack(spacing: Theme.Spacing.small) {
        Text("Couldn\u{2019}t load run history.").foregroundStyle(.secondary)
        Text(error).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
        Spacer(minLength: 0)
        if let retry = actions.retry { Button("Retry", action: retry).controlSize(.small) }
      }
      .accessibilityIdentifier("automation-detail-runs-error")
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

  /// A titled block with a muted label, 24 points below what precedes it.
  private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text(title).font(AutomationStyle.sectionLabel).foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
      content()
    }
    .padding(.top, Theme.Spacing.extraLarge)
  }
}
