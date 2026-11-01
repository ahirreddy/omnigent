import Foundation

// `execPolicyAmendment` mirrors the core's `Option<Vec<String>>`: `nil` means no policy was
// offered; a response must echo an offered policy exactly.
// swiftlint:disable discouraged_optional_collection

// Mirrors of the core's decision records (`omnigent-ffi` `decisions.rs`, built by
// `omnigent_core::decisions::Decision::from_request`, which fails closed).

/// One choice a form field offers.
nonisolated public struct FormOption: Hashable, Sendable, Identifiable {
  /// The value posted when chosen.
  public var value: String
  /// What to show.
  public var label: String
  /// Extra description.
  public var detail: String

  /// The option's identity is its value; values are unique within a field.
  public var id: String { value }

  /// Creates an option.
  /// - Parameters:
  ///   - value: Posted value.
  ///   - label: Display label.
  ///   - detail: Extra description.
  public init(value: String, label: String? = nil, detail: String = "") {
    self.value = value
    self.label = label ?? value
    self.detail = detail
  }
}

/// The native control a field needs.
nonisolated public enum FieldKind: String, Hashable, Sendable, CaseIterable {
  /// Free text.
  case text
  /// A number.
  case number
  /// A whole number.
  case integer
  /// A toggle.
  case boolean
  /// One option.
  case singleChoice
  /// Several options.
  case multipleChoice
}

/// One form field.
nonisolated public struct FormField: Hashable, Sendable, Identifiable {
  /// The `content` key.
  public var key: String
  /// Label.
  public var title: String
  /// Help text.
  public var detail: String
  /// The control.
  public var kind: FieldKind
  /// Must be answered.
  public var required: Bool
  /// Offered choices.
  public var options: [FormOption]
  /// A free-text answer is allowed besides the options.
  public var allowsCustom: Bool
  /// Render as a secure field.
  public var isSecret: Bool
  /// Lowest number.
  public var minimum: Double?
  /// Highest number.
  public var maximum: Double?
  /// Shortest text.
  public var minLength: UInt64?
  /// Longest text.
  public var maxLength: UInt64?
  /// Fewest choices.
  public var minItems: UInt64?
  /// Most choices.
  public var maxItems: UInt64?

  /// The field's identity is its key.
  public var id: String { key }

  /// Creates a field.
  /// - Parameters:
  ///   - key: Content key.
  ///   - title: Label.
  ///   - detail: Help text.
  ///   - kind: Control.
  ///   - required: Must be answered.
  ///   - options: Choices.
  ///   - allowsCustom: Free text allowed.
  ///   - isSecret: Secure entry.
  ///   - minimum: Lowest number.
  ///   - maximum: Highest number.
  ///   - minLength: Shortest text.
  ///   - maxLength: Longest text.
  ///   - minItems: Fewest choices.
  ///   - maxItems: Most choices.
  public init(
    key: String, title: String, detail: String = "", kind: FieldKind, required: Bool = true,
    options: [FormOption] = [], allowsCustom: Bool = false, isSecret: Bool = false,
    minimum: Double? = nil, maximum: Double? = nil, minLength: UInt64? = nil,
    maxLength: UInt64? = nil, minItems: UInt64? = nil, maxItems: UInt64? = nil
  ) {
    self.key = key
    self.title = title
    self.detail = detail
    self.kind = kind
    self.required = required
    self.options = options
    self.allowsCustom = allowsCustom
    self.isSecret = isSecret
    self.minimum = minimum
    self.maximum = maximum
    self.minLength = minLength
    self.maxLength = maxLength
    self.minItems = minItems
    self.maxItems = maxItems
  }
}

/// What a card asks for.
nonisolated public enum DecisionKind: Hashable, Sendable {
  /// Approve or decline, plus the card's permission options.
  case approval
  /// One answer from `options`, posted under `answerKey`.
  case choice(answerKey: String, options: [String])
  /// A typed form.
  case form(fields: [FormField])
  /// Cannot be answered natively. `externalUrl` is never opened automatically.
  case unsupported(reason: String, externalUrl: String?)
}

/// Codex and Antigravity persistence scopes.
nonisolated public enum PersistMode: String, Hashable, Sendable, CaseIterable {
  /// For the rest of this session.
  case session
  /// Persistently.
  case always
}

/// A Codex command approval.
nonisolated public struct CommandApproval: Hashable, Sendable {
  /// The command line.
  public var command: String
  /// Working directory.
  public var cwd: String?
  /// Why the agent wants to run it.
  public var reason: String?

  /// Creates a command approval.
  /// - Parameters:
  ///   - command: Command line.
  ///   - cwd: Working directory.
  ///   - reason: Why.
  public init(command: String, cwd: String? = nil, reason: String? = nil) {
    self.command = command
    self.cwd = cwd
    self.reason = reason
  }
}

/// Antigravity permission details.
nonisolated public struct AntigravityPermission: Hashable, Sendable {
  /// What Antigravity wants to do.
  public var actionDescription: String?
  /// The command prefix it offers to always allow.
  public var alwaysAllowPattern: String?

  /// Creates Antigravity details.
  /// - Parameters:
  ///   - actionDescription: What it wants to do.
  ///   - alwaysAllowPattern: The offered always-allow prefix.
  public init(actionDescription: String? = nil, alwaysAllowPattern: String? = nil) {
    self.actionDescription = actionDescription
    self.alwaysAllowPattern = alwaysAllowPattern
  }
}

/// Permission choices the request advertises beyond approve and decline.
nonisolated public struct PermissionOptions: Hashable, Sendable {
  /// Offer "approve and allow all edits".
  public var allowAllEdits: Bool
  /// Offer "approve and switch to auto mode".
  public var allowAutoMode: Bool
  /// The directory scope offered for the session.
  public var permissionDirectories: [String]
  /// The "don't ask again" scope label.
  public var rememberLabel: String?
  /// The plan under review.
  public var plan: String?
  /// Codex command details.
  public var command: CommandApproval?
  /// The command policy the user may approve, exactly as offered.
  public var execPolicyAmendment: [String]?
  /// Offered persistence modes.
  public var persistModes: [PersistMode]
  /// Antigravity details.
  public var antigravity: AntigravityPermission?

  /// Creates permission options.
  /// - Parameters:
  ///   - allowAllEdits: Offer allow-all-edits.
  ///   - allowAutoMode: Offer auto mode.
  ///   - permissionDirectories: Offered directories.
  ///   - rememberLabel: Remember scope label.
  ///   - plan: Plan under review.
  ///   - command: Codex command.
  ///   - execPolicyAmendment: Offered command policy.
  ///   - persistModes: Offered persistence modes.
  ///   - antigravity: Antigravity details.
  public init(
    allowAllEdits: Bool = false, allowAutoMode: Bool = false,
    permissionDirectories: [String] = [], rememberLabel: String? = nil, plan: String? = nil,
    command: CommandApproval? = nil, execPolicyAmendment: [String]? = nil,
    persistModes: [PersistMode] = [], antigravity: AntigravityPermission? = nil
  ) {
    self.allowAllEdits = allowAllEdits
    self.allowAutoMode = allowAutoMode
    self.permissionDirectories = permissionDirectories
    self.rememberLabel = rememberLabel
    self.plan = plan
    self.command = command
    self.execPolicyAmendment = execPolicyAmendment
    self.persistModes = persistModes
    self.antigravity = antigravity
  }

  /// Whether accepting with `mode` persistence was offered (Codex modes, or Antigravity's
  /// always-allow pattern). Mirrors `PermissionOptions::offers_persist`.
  /// - Parameter mode: The persistence mode.
  /// - Returns: `true` when offered.
  public func offersPersist(_ mode: PersistMode) -> Bool {
    persistModes.contains(mode) || antigravity?.alwaysAllowPattern != nil
  }
}

/// A decision card. A pending card is never hidden.
nonisolated public struct DecisionCard: Hashable, Sendable, Identifiable {
  /// The elicitation id.
  public var id: String
  /// The session whose stream or snapshot carried the card.
  public var carryingSessionId: String
  /// The session to resolve on (a child's id for a mirrored card).
  public var targetSessionId: String
  /// Headline.
  public var title: String
  /// Body text.
  public var detail: String
  /// What it asks for.
  public var kind: DecisionKind
  /// Extra approval choices.
  public var permissions: PermissionOptions
  /// The policy phase, when sent.
  public var phase: String?
  /// The policy name, when sent.
  public var policyName: String?
  /// The user answered locally and the server has not confirmed yet.
  public var answered: Bool

  /// Creates a card.
  /// - Parameters:
  ///   - id: Elicitation id.
  ///   - carryingSessionId: Carrying session.
  ///   - targetSessionId: Session to resolve on.
  ///   - title: Headline.
  ///   - detail: Body.
  ///   - kind: What it asks for.
  ///   - permissions: Extra choices.
  ///   - phase: Policy phase.
  ///   - policyName: Policy name.
  ///   - answered: Answered locally.
  public init(
    id: String, carryingSessionId: String, targetSessionId: String? = nil, title: String,
    detail: String, kind: DecisionKind, permissions: PermissionOptions = PermissionOptions(),
    phase: String? = nil, policyName: String? = nil, answered: Bool = false
  ) {
    self.id = id
    self.carryingSessionId = carryingSessionId
    self.targetSessionId = targetSessionId ?? carryingSessionId
    self.title = title
    self.detail = detail
    self.kind = kind
    self.permissions = permissions
    self.phase = phase
    self.policyName = policyName
    self.answered = answered
  }

  /// The card was mirrored from another (child) session.
  public var isMirrored: Bool { targetSessionId != carryingSessionId }
}

/// One form answer.
nonisolated public enum ElicitationValue: Hashable, Sendable {
  /// `null`.
  case null
  /// A boolean.
  case bool(value: Bool)
  /// An integer.
  case integer(value: Int64)
  /// A non-integer number.
  case number(value: Double)
  /// Text.
  case text(value: String)
  /// Several choices.
  case textList(values: [String])
}

/// What the user chose.
nonisolated public enum DecisionResponse: Hashable, Sendable {
  /// Accept a binary approval.
  case approve
  /// Decline a binary approval.
  case decline
  /// Dismiss any answerable card without a choice.
  case cancel
  /// One of a choice card's options.
  case answer(value: String)
  /// Values for a form, keyed by field key.
  case form(values: [String: ElicitationValue])
  /// Accept and allow all edits.
  case approveAllEdits
  /// Accept and switch to auto mode.
  case approveAutoMode
  /// Accept and allow the offered directories.
  case approveDirectories
  /// Accept and don't ask again.
  case approveRemembering
  /// Accept with the offered command policy, exactly as offered.
  case approveCommandPolicy(policy: [String])
  /// Accept with persistence.
  case approvePersist(mode: PersistMode)
  /// Decline a plan review with feedback. Must not be blank.
  case declineWithFeedback(feedback: String)

  /// A short past-tense description, for the answered state and VoiceOver.
  public var summary: String {
    switch self {
    case .approve: "Approved"
    case .decline: "Declined"
    case .cancel: "Dismissed"
    case .answer(let value): "Answered: \(value)"
    case .form: "Answers submitted"
    case .approveAllEdits: "Approved and allowed all edits"
    case .approveAutoMode: "Approved and switched to auto mode"
    case .approveDirectories: "Approved for the offered directories"
    case .approveRemembering: "Approved and remembered"
    case .approveCommandPolicy: "Approved with the command policy"
    case .approvePersist(let mode):
      mode == .always ? "Approved and always allowed" : "Approved for this session"
    case .declineWithFeedback: "Rejected with feedback"
    }
  }

  /// Whether the response changes approval behavior beyond this one request.
  public var changesStandingPermissions: Bool {
    switch self {
    case .approveAllEdits, .approveAutoMode, .approveDirectories, .approveRemembering,
      .approveCommandPolicy, .approvePersist:
      true
    case .approve, .decline, .cancel, .answer, .form, .declineWithFeedback:
      false
    }
  }
}

/// Where one card stands in the UI.
nonisolated public enum DecisionPhase: Hashable, Sendable {
  /// Waiting for the user.
  case pending
  /// A response is being sent.
  case resolving
  /// The response was sent; the server has not confirmed yet.
  case answered(summary: String)
  /// Sending failed. Nothing was resolved; the card stays answerable.
  case failed(message: String)
}

// swiftlint:enable discouraged_optional_collection
