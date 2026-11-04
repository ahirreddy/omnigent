public import Foundation

// Mirrors of the core's transcript records (`omnigent-ffi` `transcript.rs`, which mirrors
// `omnigent_core::reducer::state`). Field names match the generated Swift bindings, so the store
// adapter is a field-by-field copy.

/// Who a row belongs to.
nonisolated public enum RowRole: String, Hashable, Sendable, CaseIterable {
  /// The person using the app.
  case user
  /// The agent's reply text.
  case assistant
  /// Tool, lifecycle and other activity rows.
  case tool
}

/// What an activity row shows.
nonisolated public enum ActivityKind: String, Hashable, Sendable, CaseIterable {
  /// A function call.
  case toolCall
  /// A function call result.
  case toolResult
  /// A provider-native tool call (web search, code interpreter, MCP).
  case nativeTool
  /// A public reasoning summary.
  case reasoning
  /// Context compaction.
  case compaction
  /// A slash command or skill receipt.
  case command
  /// A shell-mode terminal command or its output.
  case terminal
  /// A model routing decision.
  case routing
  /// A session resource receipt.
  case resource
  /// A failure.
  case error
  /// Content or an event this client does not know, shown through safe display text.
  case unknown
  /// A retried model or tool call.
  case retry
  /// A generated file.
  case file
  /// A policy denial.
  case policy
  /// A client-side task the server cancelled.
  case clientTask
  /// A desktop browser action (display only).
  case browser
  /// A side question and its answer.
  case sidechat
}

/// One titled block of detail text inside an activity or a session section.
nonisolated public struct DetailSection: Hashable, Sendable, Identifiable {
  /// Stable id within its parent.
  public var id: String
  /// Heading.
  public var title: String
  /// Sanitised, bounded text.
  public var text: String
  /// Render monospaced.
  public var isCode: Bool

  /// Creates a detail section.
  /// - Parameters:
  ///   - id: Stable id within the parent.
  ///   - title: Heading.
  ///   - text: Body text.
  ///   - isCode: Render monospaced.
  public init(id: String, title: String, text: String, isCode: Bool = false) {
    self.id = id
    self.title = title
    self.text = text
    self.isCode = isCode
  }
}

/// What an attachment holds.
nonisolated public enum AttachmentKind: String, Hashable, Sendable, CaseIterable {
  /// An image.
  case image
  /// Any other file.
  case file
  /// Audio.
  case audio
  /// Video.
  case video
}

/// A display-only attachment descriptor. Views never fetch `reference` automatically.
nonisolated public struct Attachment: Hashable, Sendable, Identifiable {
  /// Stable id within the row.
  public var id: String
  /// What it holds.
  public var kind: AttachmentKind
  /// File name or a generic label.
  public var title: String
  /// A session file id or a non-embedded URL.
  public var reference: String?
  /// Media type, when sent.
  public var mimeType: String?
  /// The bytes were inline and have been dropped.
  public var isEmbedded: Bool

  /// Creates an attachment descriptor.
  /// - Parameters:
  ///   - id: Stable id within the row.
  ///   - kind: What it holds.
  ///   - title: File name or label.
  ///   - reference: File id or URL.
  ///   - mimeType: Media type.
  ///   - isEmbedded: The bytes were inline.
  public init(
    id: String, kind: AttachmentKind, title: String, reference: String? = nil,
    mimeType: String? = nil, isEmbedded: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.reference = reference
    self.mimeType = mimeType
    self.isEmbedded = isEmbedded
  }
}

/// The typed presentation of a non-text row.
nonisolated public struct Activity: Hashable, Sendable {
  /// What the row shows.
  public var kind: ActivityKind
  /// Headline, for example `Using fixture-model`.
  public var title: String
  /// One bounded line or paragraph.
  public var summary: String
  /// Status as reported or derived (`in_progress`, `completed`, `failed`, ...).
  public var status: String?
  /// Detail blocks.
  public var details: [DetailSection]
  /// An error, or a failed, error or denied status (computed by the core).
  public var isFailure: Bool

  /// Creates an activity.
  /// - Parameters:
  ///   - kind: What the row shows.
  ///   - title: Headline.
  ///   - summary: One bounded line.
  ///   - status: Reported status.
  ///   - details: Detail blocks.
  ///   - isFailure: Whether the core classified it as a failure.
  public init(
    kind: ActivityKind, title: String, summary: String = "", status: String? = nil,
    details: [DetailSection] = [], isFailure: Bool = false
  ) {
    self.kind = kind
    self.title = title
    self.summary = summary
    self.status = status
    self.details = details
    self.isFailure = isFailure
  }

  /// The text of the detail section with `id`.
  /// - Parameter id: The detail id.
  /// - Returns: Its text, if present.
  public func detail(_ id: String) -> String? {
    details.first { $0.id == id }?.text
  }
}

/// One transcript or activity row, keyed by a stable id.
nonisolated public struct Row: Hashable, Sendable, Identifiable {
  /// Stable id: the server item id, or `live:...` / `event:...` for previews.
  public var id: String
  /// Who the row belongs to.
  public var role: RowRole
  /// The plain text.
  public var text: String
  /// Still receiving deltas.
  public var isStreaming: Bool
  /// The typed presentation of a non-text row.
  public var activity: Activity?
  /// Attachment descriptors.
  public var attachments: [Attachment]
  /// The tool call the row belongs to.
  public var callId: String?
  /// The response (turn) the row belongs to.
  public var responseId: String?
  /// Cut off by a stop or interrupt.
  public var interrupted: Bool
  /// The human author.
  public var author: String?
  /// The agent that wrote it.
  public var agent: String?
  /// A live preview or event row that a persisted item may replace.
  public var isEphemeral: Bool
  /// Routine bookkeeping that belongs in an activity drawer, not the transcript.
  public var isActivityOnly: Bool
  /// When the server wrote it; live previews have none.
  public var createdAt: Date?

  /// Creates a row.
  /// - Parameters:
  ///   - id: Stable id.
  ///   - role: Owner.
  ///   - text: Plain text.
  ///   - isStreaming: Still receiving deltas.
  ///   - activity: Typed activity.
  ///   - attachments: Attachments.
  ///   - callId: Tool call id.
  ///   - responseId: Turn id.
  ///   - interrupted: Cut off.
  ///   - author: Human author.
  ///   - agent: Agent name.
  ///   - isEphemeral: Live preview or event row.
  ///   - isActivityOnly: Belongs in the activity drawer.
  ///   - createdAt: When the server wrote it.
  public init(
    id: String, role: RowRole, text: String = "", isStreaming: Bool = false,
    activity: Activity? = nil, attachments: [Attachment] = [], callId: String? = nil,
    responseId: String? = nil, interrupted: Bool = false, author: String? = nil,
    agent: String? = nil, isEphemeral: Bool = false, isActivityOnly: Bool = false,
    createdAt: Date? = nil
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.isStreaming = isStreaming
    self.activity = activity
    self.attachments = attachments
    self.callId = callId
    self.responseId = responseId
    self.interrupted = interrupted
    self.author = author
    self.agent = agent
    self.isEphemeral = isEphemeral
    self.isActivityOnly = isActivityOnly
    self.createdAt = createdAt
  }
}
