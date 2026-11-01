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
  /// - Returns: The state.
  static func state(
    _ store: ConversationStore, isStopping: Bool, dismissedError: CoreError?
  ) -> ComposerViewState {
    let composer = store.composer
    let settings = store.header?.settings
    return ComposerViewState(
      availability: availability(store), delivery: delivery(composer, dismissed: dismissedError),
      isRunning: store.isRunning, isStopping: isStopping,
      attachments: composer.attachments.items.map(attachment),
      configuration: settings.map(configuration))
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
      selectedModelId: settings.modelOverride.reportedID,
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
        builtin: option.choice.builtin)
    }
    return ComposerConfiguration(
      harness: current?.harness, harnessChoices: harnesses, selectedAgentId: current?.agentId,
      modelOptions: composer.supportsModelChoice ? models : [],
      selectedModelId: current?.modelOverride,
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
