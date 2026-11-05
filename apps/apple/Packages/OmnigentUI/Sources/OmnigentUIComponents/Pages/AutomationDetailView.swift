public import SwiftUI

/// One automation's page: name and actions, the active switch with its schedule, the prompt,
/// where and with what it runs, and its run history.
public struct AutomationDetailView: View {
  private let state: AutomationDetailState
  private let actions: AutomationDetailActions
  @State private var confirmingDelete = false

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
        section("Prompt") {
          Text(state.prompt).textSelection(.enabled)
            .accessibilityIdentifier("automation-detail-prompt")
        }
        section("Configuration") {
          Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.section) {
            GridRow {
              LabeledContent("Agent", value: state.agent)
              LabeledContent("Host", value: state.host)
            }
          }
        }
        Divider()
        section("Run history") { runs }
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
      Text(state.name).font(.largeTitle.weight(.semibold))
        .accessibilityIdentifier("automation-detail-title")
      Spacer()
      if let edit = actions.edit {
        Button("Edit automation", systemImage: "pencil", action: edit)
          .labelStyle(.iconOnly).disabled(state.isBusy)
          .accessibilityIdentifier("automation-detail-edit")
      }
      if actions.delete != nil {
        Button("Delete automation", systemImage: "trash") { confirmingDelete = true }
          .labelStyle(.iconOnly).disabled(state.isBusy)
          .accessibilityIdentifier("automation-detail-delete")
      }
      if let runNow = actions.runNow {
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
        .disabled(state.isBusy)
        .accessibilityIdentifier("automation-detail-run-now")
      }
    }
  }

  private var statusLine: some View {
    HStack(spacing: Theme.Spacing.small) {
      if let setPaused = actions.setPaused {
        Toggle(
          state.isPaused ? "Resume automation" : "Pause automation",
          isOn: Binding(get: { !state.isPaused }, set: { setPaused(!$0) })
        )
        .toggleStyle(.switch).labelsHidden().controlSize(.small)
        .disabled(state.isBusy)
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
    }
    .font(.callout)
  }

  @ViewBuilder private var runs: some View {
    if state.isLoadingRuns {
      ProgressView("Loading runs\u{2026}").frame(maxWidth: .infinity).padding()
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
          AutomationRunRowView(run: run, open: openAction(run))
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

/// One run: its status icon, when it fired, how long it took or what it is doing, and why it
/// failed. A run with a session opens it.
struct AutomationRunRowView: View {
  let run: AutomationRunRow
  let open: (@MainActor () -> Void)?
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
          if let label = run.statusLabel {
            Text(label).font(.caption).foregroundStyle(.secondary)
          }
        }
        if let reason = run.failureReason {
          Text(failureText(reason)).font(.caption).foregroundStyle(.secondary)
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
    if let open {
      Button(action: open) { row }.buttonStyle(.plain).onHover { isHovered = $0 }
    } else {
      row
    }
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
