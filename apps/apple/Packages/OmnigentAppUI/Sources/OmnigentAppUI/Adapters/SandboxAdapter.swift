import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The open session's managed sandbox for the titlebar's status control, and its launch for the
/// lines that would otherwise call a launching session disconnected. The rules are the core's
/// (`sandboxState`); this maps what the conversation reports into them and back out.
enum SandboxAdapter {
  /// The sandbox of the session `store` shows, `nil` for a session without one, for a child
  /// session (it runs under its parent's) and until the header loads.
  /// - Parameters:
  ///   - store: The conversation.
  ///   - environment: Where a session on a host runs, as the host list says.
  /// - Returns: The state.
  static func state(
    _ store: ConversationStore, environment: @MainActor (String) -> SessionEnvironment?
  ) -> SandboxStatusState? {
    guard let header = store.header, let settings = header.settings, settings.parentId == nil,
      settings.sideChatSourceId == nil
    else { return nil }
    let isRunning = header.status == .running
    let signals = SandboxSignals(
      launch: header.sandboxLaunch, profile: settings.sandboxProfile,
      hostSandbox: hostSandbox(settings.hostId.flatMap(environment)), hostId: settings.hostId,
      hostOnline: settings.hostOnline, runnerOnline: settings.runnerOnline,
      hostResumable: settings.hostResumable, turnActive: isRunning,
      canEdit: !header.readOnly && !header.archived,
      // Owners hold level 4 or above; an unshared session reports no level.
      isOwner: header.permissionLevel.map { $0 >= 4 } ?? true)
    guard let sandbox = sandboxState(signals: signals) else { return nil }
    var state = SandboxStatusState(
      mark: mark(sandbox.phase), title: sandbox.title, summary: sandbox.summary,
      operations: sandbox.operations.map(operation))
    state.profile = sandbox.profile
    state.hint = sandbox.hint
    state.details = sandbox.details
    state.error = sandbox.error
    state.host = link(sandbox.hostOnline)
    state.runner = link(sandbox.runnerOnline)
    state.isTurnRunning = isRunning
    return state
  }

  /// The mark a phase shows on the control's icon.
  static func mark(_ phase: SandboxPhase) -> SandboxStatusState.Mark {
    switch phase {
    case .launching, .waking: .progress
    case .actionRequired: .attention
    case .failed: .failed
    case .running: .running
    case .agentAsleep, .asleep, .offline, .unknown: .resting
    }
  }

  // swiftlint:disable:next discouraged_optional_boolean
  static func link(_ isOnline: Bool?) -> SandboxStatusState.Link {
    switch isOnline {
    case true?: .online
    case false?: .offline
    case nil: .unreported
    }
  }

  static func operation(_ state: SandboxOperationState) -> SandboxStatusState.Operation {
    SandboxStatusState.Operation(
      id: operationID(state.operation), title: state.title, help: state.help,
      unavailableReason: state.unavailableReason, isDestructive: state.isDestructive)
  }

  static func operationID(_ operation: SandboxOperation) -> String {
    switch operation {
    case .wake: "wake"
    case .stop: "stop"
    }
  }

  /// The panel's buttons over `store`: one request each, and why the server refused.
  static func actions(_ store: ConversationStore) -> SandboxStatusActions {
    SandboxStatusActions { id in
      do throws(CoreError) {
        let operation = id == operationID(.stop) ? SandboxOperation.stop : .wake
        let outcome = try await store.performSandboxOperation(operation)
        // Nothing was woken, which the user who pressed Wake should hear.
        return outcome == .alreadyRunning ? "The agent is already connected." : nil
      } catch {
        return error.message
      }
    }
  }

  /// A host's sandbox name in the host list, `nil` for a machine and for an unlisted host.
  static func hostSandbox(_ environment: SessionEnvironment?) -> String? {
    if case .sandbox(let label) = environment { return label }
    return nil
  }

  /// Where an unfinished launch stands, `nil` without one and once it is ready.
  static func launchNote(_ launch: SandboxLaunch?) -> SandboxLaunchNote? {
    guard let launch, launch.stage != .ready else { return nil }
    let label = sandboxLaunchLabel(stage: launch.stage)
    switch launch.stage {
    case .failed: return SandboxLaunchNote(label: label, standing: .failed, note: launch.error)
    case .actionRequired:
      return SandboxLaunchNote(label: label, standing: .waiting, note: launch.details)
    default: return SandboxLaunchNote(label: label)
    }
  }
}

extension ConversationContainer {
  /// What the sandbox panel's buttons do for this conversation.
  var sandboxActions: SandboxStatusActions { SandboxAdapter.actions(conversation) }
}
