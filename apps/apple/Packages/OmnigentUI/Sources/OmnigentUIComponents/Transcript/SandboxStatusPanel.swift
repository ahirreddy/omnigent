import SwiftUI

/// The sandbox control's panel: the provider and profile, the state in words, what the user
/// must do or why the launch failed, the host's and the agent's links, and one button per
/// operation the server supports, each saying why it does not apply when it does not.
struct SandboxStatusPanel: View {
  let state: SandboxStatusState
  let actions: SandboxStatusActions
  let model: SandboxPanelModel

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      header
      Grid(
        alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.medium,
        verticalSpacing: Theme.Spacing.small
      ) {
        row("State", state.statusLine, identifier: "sandbox-panel-state")
        if let details = state.details {
          row(
            "Needs you", details, style: AnyShapeStyle(Theme.attention),
            identifier: "sandbox-panel-details")
        }
        if let error = state.error {
          row(
            "Error", error, style: AnyShapeStyle(Theme.failure),
            identifier: "sandbox-panel-error")
        }
        row("Host", state.host.label, identifier: "sandbox-panel-host")
        row("Agent", state.runner.label, identifier: "sandbox-panel-agent")
      }
      if let hint = state.hint {
        Text(hint).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let perform = actions.perform, !state.operations.isEmpty {
        Divider()
        ForEach(state.operations) { operation in
          SandboxOperationRow(
            operation: operation, isTurnRunning: state.isTurnRunning, model: model,
            perform: perform)
        }
        if let failure = model.failure {
          Label {
            Text(failure).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
          }
          .font(.callout)
          .foregroundStyle(Theme.failure)
          .accessibilityIdentifier("sandbox-operation-error")
        }
      }
    }
    .padding(Theme.Spacing.large)
    .frame(width: 320, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("sandbox-panel")
  }

  private var header: some View {
    HStack(alignment: .center, spacing: Theme.Spacing.small) {
      Image(systemName: "shippingbox")
        .font(.title3)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
        .overlay(alignment: .bottomTrailing) { SandboxStatusMark(mark: state.mark) }
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        Text(state.title).font(.headline)
        if let profile = state.profile {
          Text("Profile: \(profile)").font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("sandbox-panel-profile")
        }
      }
    }
  }

  private func row(
    _ title: String, _ value: String, style: AnyShapeStyle = AnyShapeStyle(.primary),
    identifier: String
  ) -> some View {
    GridRow {
      Text(title)
        .font(.callout)
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
      Text(value)
        .font(.callout)
        .foregroundStyle(style)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .accessibilityIdentifier(identifier)
    }
  }
}

/// One operation: its button, and under it what it does or why it does not apply. A destructive
/// one asks first while a turn runs.
private struct SandboxOperationRow: View {
  let operation: SandboxStatusState.Operation
  let isTurnRunning: Bool
  let model: SandboxPanelModel
  let perform: @MainActor (String) async -> String?

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      if model.confirmingID == operation.id {
        Text("A turn is running. \(operation.title) ends it.")
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: Theme.Spacing.small) {
          Button(operation.title, role: .destructive, action: request)
            .accessibilityIdentifier("sandbox-operation-\(operation.id)-confirm")
          Button("Cancel", role: .cancel) { model.cancelConfirmation() }
            .accessibilityIdentifier("sandbox-operation-\(operation.id)-cancel")
        }
      } else {
        Button(action: request) {
          HStack(spacing: Theme.Spacing.extraSmall) {
            if model.runningID == operation.id { ProgressView().controlSize(.small) }
            Text(operation.title)
          }
        }
        .disabled(operation.unavailableReason != nil || model.runningID != nil)
        .help(operation.unavailableReason ?? operation.help)
        .accessibilityIdentifier("sandbox-operation-\(operation.id)")
        Text(operation.unavailableReason ?? operation.help)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("sandbox-operation-\(operation.id)-note")
      }
    }
  }

  private func request() {
    model.request(operation, isTurnRunning: isTurnRunning, perform: perform)
  }
}
