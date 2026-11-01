public import Foundation
public import UniformTypeIdentifiers

// `HarnessChoice.builtin` mirrors the core's `Option<bool>` (not reported is not false).
// swiftlint:disable discouraged_optional_boolean

/// Whether the composer can send, and why not. The reason comes from the core
/// (read-only, archived, host offline, runner unbound, ...) and is shown verbatim.
nonisolated public enum ComposerAvailability: Hashable, Sendable {
  /// Sending is possible.
  case available
  /// Sending is not possible right now.
  case unavailable(reason: String)

  /// The reason, when unavailable.
  public var reason: String? {
    if case .unavailable(let reason) = self { return reason }
    return nil
  }
}

/// Where the last send stands.
nonisolated public enum DeliveryState: Hashable, Sendable {
  /// Nothing in flight.
  case idle
  /// A message is being sent.
  case sending
  /// The send may or may not have reached the server. Another send is blocked until the user
  /// confirms they checked the conversation; the core never retries on its own.
  case uncertain(message: String)
  /// The send failed and nothing was delivered. The draft is kept.
  case failed(message: String)
}

/// The upload state of one draft attachment.
nonisolated public enum DraftAttachmentState: Hashable, Sendable {
  /// Read and checked locally; uploads on send.
  case ready
  /// Uploading.
  case uploading(progress: Double?)
  /// Uploaded; the server file id is known.
  case uploaded
  /// Rejected or failed; the message says why.
  case failed(message: String)
}

/// One attachment in the composer draft.
nonisolated public struct DraftAttachment: Hashable, Sendable, Identifiable {
  /// Stable draft id.
  public var id: String
  /// File name.
  public var title: String
  /// What it holds.
  public var kind: AttachmentKind
  /// Size in bytes, when known.
  public var byteCount: Int64?
  /// Upload state.
  public var state: DraftAttachmentState

  /// Creates a draft attachment.
  /// - Parameters:
  ///   - id: Draft id.
  ///   - title: File name.
  ///   - kind: What it holds.
  ///   - byteCount: Size in bytes.
  ///   - state: Upload state.
  public init(
    id: String, title: String, kind: AttachmentKind, byteCount: Int64? = nil,
    state: DraftAttachmentState = .ready
  ) {
    self.id = id
    self.title = title
    self.kind = kind
    self.byteCount = byteCount
    self.state = state
  }
}

/// Something the user added to the composer. The host reads, checks and stages it with the core's
/// attachment policy; the composer only collects it.
nonisolated public enum ComposerAttachmentInput: Hashable, Sendable {
  /// A file URL from the importer, a drop or a paste. Importer URLs are security scoped: the host
  /// must call `startAccessingSecurityScopedResource()` while it reads the file.
  case file(url: URL)
  /// Raw bytes from the photo picker or a pasted image.
  case data(Data, suggestedName: String, contentType: UTType)
}

/// One harness the session could switch to (the core's `HarnessChoice`).
nonisolated public struct HarnessChoice: Hashable, Sendable, Identifiable {
  /// Agent id.
  public var id: String
  /// Display name.
  public var name: String
  /// Harness as sent.
  public var harness: String?
  /// Built in.
  public var builtin: Bool?
  /// Why it cannot be chosen now (the core's rule); shown, never hidden.
  public var unavailableReason: String?

  /// Creates a harness choice.
  /// - Parameters:
  ///   - id: Agent id.
  ///   - name: Display name.
  ///   - harness: Harness id.
  ///   - builtin: Built in.
  ///   - unavailableReason: Why it cannot be chosen.
  public init(
    id: String, name: String, harness: String? = nil, builtin: Bool? = nil,
    unavailableReason: String? = nil
  ) {
    self.id = id
    self.name = name
    self.harness = harness
    self.builtin = builtin
    self.unavailableReason = unavailableReason
  }
}

/// What the composer renders. The draft text itself is a binding owned by the host.
nonisolated public struct ComposerViewState: Hashable, Sendable {
  /// Whether sending is possible.
  public var availability: ComposerAvailability
  /// The last send's state.
  public var delivery: DeliveryState
  /// A turn is running; the send button becomes Stop.
  public var isRunning: Bool
  /// An interrupt is in flight.
  public var isStopping: Bool
  /// Draft attachments.
  public var attachments: [DraftAttachment]
  /// The host accepts attachments on this server.
  public var acceptsAttachments: Bool
  /// The harness, model and effort picker, when the harness reports one.
  public var configuration: ComposerConfiguration?
  /// Placeholder text, in the web's words ("Send a message…").
  public var placeholder: String
  /// The Host chip and its menu.
  public var hosts: ComposerHosts?
  /// The approval-mode (Permission) chip; ⇧Tab cycles it.
  public var approvalModes: ApprovalModes?
  /// The context tray above the card (directory, branch, PR, context use).
  public var tray: ComposerTray?
  /// Commands and skills for the `/` menu.
  public var slashCommands: [SlashCommand]
  /// Workspace paths for the `@` menu.
  public var mentionCandidates: [String]
  /// Queued and steering messages while the agent works.
  public var queue: [QueuedMessage]
  /// In a session, or starting a new one (Start session).
  public var purpose: ComposerPurpose
  /// The "Submit with ⌘ + Enter" setting: Return inserts a newline instead of sending.
  public var submitWithCommandReturn: Bool
  /// Agent, host, workspace and server, for the context row.
  public var context: ExecutionContext?
  /// A message sent mid-turn steers the running turn; otherwise it waits for the turn to end.
  public var canSteer: Bool

  /// Creates composer state.
  /// - Parameters:
  ///   - availability: Can send.
  ///   - delivery: Last send state.
  ///   - isRunning: A turn is running.
  ///   - isStopping: Interrupt in flight.
  ///   - attachments: Draft attachments.
  ///   - acceptsAttachments: Attachments are supported.
  ///   - configuration: Model picker.
  ///   - placeholder: Placeholder.
  ///   - hosts: Host chip.
  ///   - approvalModes: Permission chip.
  ///   - tray: Context tray.
  ///   - slashCommands: Slash commands.
  ///   - mentionCandidates: Mention paths.
  ///   - queue: Queued messages.
  ///   - purpose: Session or start.
  ///   - submitWithCommandReturn: Command-Return submits.
  ///   - context: Execution context.
  ///   - canSteer: Mid-turn messages steer.
  public init(
    availability: ComposerAvailability = .available, delivery: DeliveryState = .idle,
    isRunning: Bool = false, isStopping: Bool = false, attachments: [DraftAttachment] = [],
    acceptsAttachments: Bool = true, configuration: ComposerConfiguration? = nil,
    placeholder: String = "Send a message\u{2026}", hosts: ComposerHosts? = nil,
    approvalModes: ApprovalModes? = nil, tray: ComposerTray? = nil,
    slashCommands: [SlashCommand] = [], mentionCandidates: [String] = [],
    queue: [QueuedMessage] = [], purpose: ComposerPurpose = .session,
    submitWithCommandReturn: Bool = false, context: ExecutionContext? = nil,
    canSteer: Bool = false
  ) {
    self.availability = availability
    self.delivery = delivery
    self.isRunning = isRunning
    self.isStopping = isStopping
    self.attachments = attachments
    self.acceptsAttachments = acceptsAttachments
    self.configuration = configuration
    self.placeholder = placeholder
    self.hosts = hosts
    self.approvalModes = approvalModes
    self.tray = tray
    self.slashCommands = slashCommands
    self.mentionCandidates = mentionCandidates
    self.queue = queue
    self.purpose = purpose
    self.submitWithCommandReturn = submitWithCommandReturn
    self.context = context
    self.canSteer = canSteer
  }
}

/// Composer actions.
public struct ComposerActions {
  /// Send the draft (and attachments).
  public var send: @MainActor () -> Void
  /// Interrupt the running turn.
  public var interrupt: (@MainActor () -> Void)?
  /// Stage new attachments.
  public var addAttachments: (@MainActor ([ComposerAttachmentInput]) -> Void)?
  /// Remove a draft attachment.
  public var removeAttachment: (@MainActor (DraftAttachment) -> Void)?
  /// Choose a model id (`nil` for the harness default).
  public var selectModel: (@MainActor (String?) -> Void)?
  /// Choose a reasoning effort (`nil` for the model default).
  public var selectEffort: (@MainActor (String?) -> Void)?
  /// Switch harness (agent id).
  public var selectAgent: (@MainActor (String) -> Void)?
  /// The user checked the conversation after an uncertain send; allow another send.
  public var acknowledgeUncertainDelivery: (@MainActor () -> Void)?
  /// Dismiss a failed delivery message.
  public var dismissDeliveryError: (@MainActor () -> Void)?
  /// Composer extras: host, approval mode, dictation, queue, Add menu.
  public var extras: ComposerExtraActions

  /// Creates actions.
  /// - Parameters:
  ///   - send: Send.
  ///   - interrupt: Stop the turn.
  ///   - addAttachments: Stage attachments.
  ///   - removeAttachment: Remove one.
  ///   - selectModel: Choose a model.
  ///   - selectEffort: Choose an effort.
  ///   - selectAgent: Switch harness.
  ///   - acknowledgeUncertainDelivery: Allow another send.
  ///   - dismissDeliveryError: Dismiss a failure.
  ///   - extras: Host, mode, dictation, queue and Add menu actions.
  public init(
    send: @escaping @MainActor () -> Void, interrupt: (@MainActor () -> Void)? = nil,
    addAttachments: (@MainActor ([ComposerAttachmentInput]) -> Void)? = nil,
    removeAttachment: (@MainActor (DraftAttachment) -> Void)? = nil,
    selectModel: (@MainActor (String?) -> Void)? = nil,
    selectEffort: (@MainActor (String?) -> Void)? = nil,
    selectAgent: (@MainActor (String) -> Void)? = nil,
    acknowledgeUncertainDelivery: (@MainActor () -> Void)? = nil,
    dismissDeliveryError: (@MainActor () -> Void)? = nil,
    extras: ComposerExtraActions = ComposerExtraActions()
  ) {
    self.send = send
    self.interrupt = interrupt
    self.addAttachments = addAttachments
    self.removeAttachment = removeAttachment
    self.selectModel = selectModel
    self.selectEffort = selectEffort
    self.selectAgent = selectAgent
    self.acknowledgeUncertainDelivery = acknowledgeUncertainDelivery
    self.dismissDeliveryError = dismissDeliveryError
    self.extras = extras
  }
}

// swiftlint:enable discouraged_optional_boolean
