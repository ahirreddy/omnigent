import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import UniformTypeIdentifiers

/// Builds the composer's view state from a ``ConversationStore`` and turns the composer's
/// inputs into store calls.
enum ComposerAdapter {
  /// The composer's view state.
  /// - Parameters:
  ///   - store: The conversation.
  ///   - isStopping: An interrupt is in flight.
  ///   - dismissedError: A send failure the user dismissed; it stays hidden until a new one.
  ///   - server: The connected server, for the execution context.
  /// - Returns: The state.
  static func state(
    _ store: ConversationStore, isStopping: Bool, dismissedError: CoreError?,
    server: OmnigentCoreFFI.ConnectedServer? = nil
  ) -> ComposerViewState {
    let composer = store.composer
    let settings = store.header?.settings
    return ComposerViewState(
      availability: availability(store), delivery: delivery(composer, dismissed: dismissedError),
      isRunning: store.isRunning, isStopping: isStopping,
      attachments: composer.attachments.items.map(attachment),
      configuration: composer.configuration == nil
        ? settings.map(configuration) : configuration(composer),
      approvalModes: composer.approvalModeMenu.map(approvalModes),
      queue: composer.queue.items.map(queued),
      context: context(store, server: server), canSteer: composer.supportsSteering)
  }

  /// The approval-mode chip from the core's menu: clear names, the harness's own names, risk.
  static func approvalModes(_ menu: OmnigentCoreFFI.ApprovalModeMenu) -> ApprovalModes {
    ApprovalModes(
      title: "\(menu.harness) approvals",
      options: menu.options.map { option in
        ApprovalModeOption(
          id: option.value, label: option.title, detail: option.description,
          harnessLabel: option.harnessTitle, risk: risk(option.risk),
          isSwitchable: option.switchable)
      },
      selectedID: menu.selected)
  }

  static func risk(_ risk: OmnigentCoreFFI.ApprovalRisk) -> OmnigentUIComponents.ApprovalRisk {
    switch risk {
    case .readOnly: .readOnly
    case .ask: .ask
    case .autoEdit: .autoEdit
    case .autoApprove: .autoApprove
    case .fullAccess: .fullAccess
    }
  }

  static func queued(_ item: MessageQueue.Item) -> QueuedMessage {
    let state: QueuedMessage.State =
      switch item.state {
      case .queued: .queued
      case .sending: .sending
      case .failed(let message): .failed(message: message)
      }
    return QueuedMessage(id: String(item.id), text: item.text, state: state)
  }

  /// Where the session runs: agent, host, workspace, server and sandbox, and why nothing can
  /// run there now.
  static func context(
    _ store: ConversationStore, server: OmnigentCoreFFI.ConnectedServer?
  ) -> ExecutionContext {
    let composer = store.composer
    let configuration = composer.configuration
    let harness = configuration?.harness ?? store.header?.settings?.harness
    let workspace = composer.workspace.flatMap { $0.hasPrefix("/") || $0.hasPrefix("~") ? $0 : nil }
    let sandbox = store.sections.first { $0.id == "sandbox" }.map {
      "Managed sandbox \u{00B7} \($0.summary)"
    }
    return ExecutionContext(
      agent: composer.configurationLabels?.harness ?? HarnessAppearance(harness: harness).label,
      harness: harness,
      host: ExecutionContext.hostDisplayName(composer.configurationCatalog?.host?.name),
      hostKind: sandbox == nil ? .machine : .cloud,
      isHostOnline: configuration?.hostOnline ?? store.header?.settings?.hostOnline,
      server: ExecutionContext.serverDisplayName(
        name: server?.serverName, baseURL: server?.baseUrl),
      directory: workspace, branch: configuration?.gitBranch, sandbox: sandbox,
      unavailableReason: composer.executionUnavailableReason)
  }

  /// The composer's queue and approval-mode actions over the store. A queue change while no
  /// turn runs drains it at once.
  static func extras(
    _ composer: ComposerStore, isRunning: @escaping @MainActor () -> Bool
  ) -> ComposerExtraActions {
    let drain: @MainActor () -> Void = {
      Task { await composer.drainQueue(isRunning: isRunning()) }
    }
    return ComposerExtraActions(
      selectApprovalMode: { mode in Task { await composer.selectApprovalMode(mode.id) } },
      editQueued: { message, text in
        guard let id = Int(message.id) else { return }
        composer.editQueued(id, text: text)
        drain()
      },
      sendQueuedNow: { message in
        guard let id = Int(message.id) else { return }
        Task { await composer.sendQueuedNow(id) }
      },
      removeQueued: { message in
        guard let id = Int(message.id) else { return }
        composer.removeQueued(id)
        drain()
      },
      moveQueued: { offsets, destination in
        composer.moveQueued(fromOffsets: offsets, toOffset: destination)
      },
      queueDraft: {
        composer.queueDraft()
        drain()
      })
  }

  static func availability(_ store: ConversationStore) -> ComposerAvailability {
    if store.isClosed { return .unavailable(reason: "This session is no longer available.") }
    if let header = store.header {
      if header.readOnly { return .unavailable(reason: "You can read this session but not send.") }
      if header.archived { return .unavailable(reason: "This session is archived.") }
    }
    if !store.isHydrated { return .unavailable(reason: "Waiting for the session to load\u{2026}") }
    return .available
  }

  static func delivery(_ composer: ComposerStore, dismissed: CoreError?) -> DeliveryState {
    if composer.isSending { return .sending }
    let error = composer.lastError == dismissed ? nil : composer.lastError
    if composer.isBlocked {
      return .uncertain(
        message: error?.message
          ?? "The last message may not have been delivered. Check the transcript, then continue.")
    }
    if let error { return .failed(message: error.message) }
    return .idle
  }

  static func attachment(_ item: OmnigentCoreFFI.DraftAttachment)
    -> OmnigentUIComponents.DraftAttachment
  {
    let state: DraftAttachmentState =
      switch item.status {
      case .staged: .ready
      case .uploading: .uploading(progress: nil)
      case .uploaded: .uploaded
      case .failed(let message): .failed(message: message)
      case .uncertain(let message): .failed(message: message)
      }
    return OmnigentUIComponents.DraftAttachment(
      id: String(item.id), title: item.filename, kind: item.isImage ? .image : .file,
      byteCount: Int64(clamping: item.byteCount), state: state)
  }

  static func configuration(_ settings: OmnigentCoreFFI.SessionSettings)
    -> ComposerConfiguration
  {
    ComposerConfiguration(
      harness: settings.harness, selectedAgentId: settings.agentId,
      modelOptions: settings.modelOptions.map(OmnigentUIComponents.ModelOption.init),
      selectedModelId: settings.modelOverride.reportedID, baseModel: settings.baseModel,
      selectedEffort: settings.reasoningEffort.reportedID)
  }

  /// The model, effort and harness menus from the composer's loaded configuration (the
  /// core's labels, model list with the host preview merged in, and harness verdicts).
  static func configuration(_ composer: ComposerStore) -> ComposerConfiguration {
    let current = composer.configuration
    let models = composer.modelChoices.map { choice in
      OmnigentUIComponents.ModelOption(
        id: choice.value, model: choice.model, displayName: choice.title,
        defaultReasoningEffort: choice.defaultReasoningEffort,
        supportedReasoningEfforts: composer.efforts(for: choice.value),
        isDefault: choice.isDefault ?? false, hidden: choice.hidden ?? false)
    }
    let harnesses = composer.harnessOptions.map { option in
      OmnigentUIComponents.HarnessChoice(
        id: option.choice.id, name: option.choice.title, harness: option.choice.harness,
        builtin: option.choice.builtin,
        unavailableReason: option.isCurrent ? nil : option.unavailableReason)
    }
    return ComposerConfiguration(
      harness: current?.harness, agentName: composer.configurationLabels?.harness,
      harnessChoices: harnesses, selectedAgentId: current?.agentId,
      modelOptions: composer.supportsModelChoice ? models : [],
      selectedModelId: current?.modelOverride, baseModel: current?.baseModel,
      selectedEffort: composer.supportsEffortChoice ? current?.effort : nil,
      isApplying: composer.isApplyingConfiguration,
      errorMessage: composer.configurationError?.message)
  }

  /// Stages each input and uploads it. Core failures stay on the composer's error; files that
  /// could not be read are returned for the caller to show.
  /// - Parameters:
  ///   - inputs: Files or data the user added.
  ///   - composer: The composer.
  /// - Returns: One message per file that could not be read.
  static func add(_ inputs: [ComposerAttachmentInput], to composer: ComposerStore) async
    -> [String]
  {
    var failures: [String] = []
    for input in inputs {
      let before = Set(composer.attachments.items.map(\.id))
      switch input {
      case .file(let url):
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
          let data = try Data(contentsOf: url)
          let type = UTType(filenameExtension: url.pathExtension)
          composer.addAttachment(
            filename: url.lastPathComponent, mediaType: type?.preferredMIMEType, data: data)
        } catch {
          failures.append("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
          continue
        }
      case .data(let data, let name, let type):
        composer.addAttachment(filename: name, mediaType: type.preferredMIMEType, data: data)
      }
      for item in composer.attachments.items where !before.contains(item.id) {
        await composer.upload(item.id)
      }
    }
    return failures
  }
}

extension OmnigentCoreFFI.ReportedValue {
  fileprivate var reportedID: String? {
    if case .value(let value) = self { return value }
    return nil
  }
}
