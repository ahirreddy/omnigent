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
  ///   - submitWithCommandReturn: Return inserts a newline and Command-Return sends.
  /// - Returns: The state.
  static func state(
    _ store: ConversationStore, isStopping: Bool, dismissedError: CoreError?,
    server: OmnigentCoreFFI.ConnectedServer? = nil, submitWithCommandReturn: Bool = false
  ) -> ComposerViewState {
    let composer = store.composer
    let settings = store.header?.settings
    var state = ComposerViewState(
      availability: availability(store), delivery: delivery(composer, dismissed: dismissedError),
      isRunning: store.isRunning, isStopping: isStopping,
      attachments: composer.attachments.items.map(attachment),
      configuration: composer.configuration == nil
        ? settings.map(configuration) : configuration(composer),
      approvalModes: composer.approvalModeMenu.map(approvalModes),
      slashCommands: composer.slashCommands.map(slashCommand),
      mentionCandidates: composer.mentionCandidates,
      queue: composer.queue.items.map(queued),
      submitWithCommandReturn: submitWithCommandReturn,
      context: context(store, server: server), canSteer: composer.supportsSteering)
    state.isReadOnly = isReadOnly(store)
    state.commandNotice = composer.commandNotice
    state.slashCommandsNote = composer.skillsProblem
    state.mentionsNote = composer.mentionProblem
    state.mentions = composer.mentions
    state.approvalPickerRequest = composer.approvalPickerRequests
    state.connection = connection(store)
    state.liveness = LivenessAdapter.notice(store, serverURL: server?.baseUrl)
    if let fraction = contextFraction(store.sections) {
      state.tray = ComposerTray(contextFraction: fraction)
    }
    return state
  }

  /// How full the context window is, from the core's usage section; `nil` until both the
  /// tokens in context and the window are reported.
  static func contextFraction(_ sections: [OmnigentCoreFFI.EventSection]) -> Double? {
    guard let usage = sections.first(where: { $0.id == "usage" }) else { return nil }
    func value(_ id: String) -> Double? {
      usage.details.first { $0.id == id }.flatMap { Double($0.text) }
    }
    guard let tokens = value("context_tokens"), let window = value("context_window"), window > 0
    else { return nil }
    return min(1, max(0, tokens / window))
  }

  static func slashCommand(_ command: OmnigentCoreFFI.SlashCommand)
    -> OmnigentUIComponents.SlashCommand
  {
    OmnigentUIComponents.SlashCommand(
      name: command.name, prefix: command.prefix, description: command.description,
      isSkill: command.isSkill)
  }

  /// The stream's state under the composer while it is not live. A closed or superseded
  /// session has its own banner, so it shows nothing here.
  static func connection(_ store: ConversationStore) -> ComposerConnectionNotice? {
    guard !store.isClosed, store.supersededBy == nil,
      let message = ConversationAdapter.connectionStatus(store)
    else { return nil }
    switch store.link {
    case .closed, .stopped, .failed:
      return ComposerConnectionNotice(message: message, isFailure: true)
    default: return ComposerConnectionNotice(message: message)
    }
  }

  /// Whether the session can never take a message from this viewer (read-only, archived or
  /// closed), unlike a session still loading.
  static func isReadOnly(_ store: ConversationStore) -> Bool {
    store.isClosed || store.header.map { $0.readOnly || $0.archived } ?? false
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
      case .waitingForHost: .waitingForHost
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

  /// The composer's queue, approval-mode, history and mention actions over the store. A queue
  /// change while no turn runs drains it at once.
  static func extras(
    _ composer: ComposerStore, isRunning: @escaping @MainActor () -> Bool,
    reconnect: (@MainActor () -> Void)? = nil, prompts: (@MainActor () -> [String])? = nil
  ) -> ComposerExtraActions {
    let drain: @MainActor () -> Void = {
      Task { await composer.drainQueue(isRunning: isRunning()) }
    }
    var extras = ComposerExtraActions(
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
      recallPrevious: recall(prompts),
      queueDraft: {
        composer.queueDraft()
        drain()
      },
      reconnect: reconnect,
      dismissCommandNotice: { composer.dismissCommandNotice() })
    extras.history = history(composer, prompts: prompts)
    extras.attachMention = { composer.addMention($0) }
    extras.removeMention = { composer.removeMention($0) }
    extras.liveness.checkAgain = reconnect
    return extras
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

extension ComposerAdapter {
  /// The newest prompt, for composers that recall one (the CLI style).
  static func recall(_ prompts: (@MainActor () -> [String])?) -> (@MainActor () -> String?)? {
    guard let prompts else { return nil }
    return { prompts().last }
  }

  /// The user's messages, oldest first, for Up and Down recall; read on the key press only.
  static func prompts(_ store: ConversationStore) -> [String] {
    store.rows.compactMap { $0.role == .user && !$0.text.isEmpty ? $0.text : nil }
  }

  /// Up and Down recall, pulling back the last queued message, and ⌘Return's send-all.
  static func history(
    _ composer: ComposerStore, prompts: (@MainActor () -> [String])?
  ) -> ComposerHistoryActions {
    ComposerHistoryActions(
      prompts: prompts, takeLastQueued: { composer.takeLastQueued() },
      sendAllQueued: { Task { await composer.sendAllQueuedNow() } })
  }
}
