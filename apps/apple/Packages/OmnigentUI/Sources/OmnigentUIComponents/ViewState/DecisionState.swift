import Foundation

// `execPolicyAmendment` mirrors the core's `Option<Vec<String>>`: `nil` means no policy was
// offered; a response must echo an offered policy exactly.
// swiftlint:disable discouraged_optional_collection

// Mirrors of the core's decision records (`omnigent-ffi` `decisions.rs`, built by
// `omnigent_core::decisions::Decision::from_request`, which fails closed).

/// What a card asks for.
nonisolated public enum DecisionKind: Hashable, Sendable {
  /// Approve or decline, plus the card's permission options.
  case approval
  /// One answer from `options`, posted under `answerKey`.
  case choice(answerKey: String, options: [String])
  /// A typed form.
  case form(fields: [FormField])
  /// A page to complete, then Done (``DecisionResponse/approve``) or Decline. The page is only
  /// ever opened when the user asks.
  case externalPage(url: String)
  /// Cannot be answered natively. `externalUrl` is never opened automatically.
  case unsupported(reason: String, externalUrl: String?)
}

/// A permission mode an approval can switch the agent to (Claude's modes).
nonisolated public enum PermissionMode: String, Hashable, Sendable, CaseIterable {
  /// Asks before edits and commands.
  case `default`
  /// Edits run without asking.
  case acceptEdits
  /// Plans without changing anything.
  case plan
  /// Nothing asks.
  case bypassPermissions
  /// Denies what would ask.
  case dontAsk
  /// A classifier decides.
  case auto
}

/// One update a request offers to apply with an approval: a rule, a mode switch, directories.
nonisolated public struct PermissionSuggestion: Hashable, Sendable {
  /// What it does, in one sentence: "Allow Bash(npm test:*) in this project".
  public var label: String
  /// It outlives this session (it is saved to settings).
  public var persists: Bool

  /// Creates a suggestion.
  /// - Parameters:
  ///   - label: What it does.
  ///   - persists: It outlives this session.
  public init(label: String, persists: Bool = false) {
    self.label = label
    self.persists = persists
  }
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
  /// The files an edit would change, when the core provides them.
  public var files: [DecisionFileChange]
  /// The updates the request suggests, offered together as one choice
  /// (``DecisionResponse/approveSuggestions``).
  public var suggestions: [PermissionSuggestion]
  /// The modes approving the plan may switch to (``DecisionResponse/approvePlanMode(mode:)``).
  public var planModes: [PermissionMode]

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
  ///   - files: Files an edit would change.
  ///   - suggestions: Suggested updates.
  ///   - planModes: Modes a plan approval may switch to.
  public init(
    allowAllEdits: Bool = false, allowAutoMode: Bool = false,
    permissionDirectories: [String] = [], rememberLabel: String? = nil, plan: String? = nil,
    command: CommandApproval? = nil, execPolicyAmendment: [String]? = nil,
    persistModes: [PersistMode] = [], antigravity: AntigravityPermission? = nil,
    files: [DecisionFileChange] = [], suggestions: [PermissionSuggestion] = [],
    planModes: [PermissionMode] = []
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
    self.files = files
    self.suggestions = suggestions
    self.planModes = planModes
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
  /// The agent's or policy's message on its own, when the core separates it from ``detail``.
  public var message: String?
  /// The gated tool call's input, formatted, when the core separates it from ``detail``.
  public var toolInput: String?
  /// What it asks for.
  public var kind: DecisionKind
  /// Extra approval choices.
  public var permissions: PermissionOptions
  /// The policy phase, when sent.
  public var phase: String?
  /// The policy name, when sent.
  public var policyName: String?
  /// A decline can carry feedback the agent receives (``DecisionResponse/declineWithFeedback(feedback:)``).
  public var acceptsFeedback: Bool
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
  ///   - acceptsFeedback: A decline can carry feedback.
  ///   - answered: Answered locally.
  ///   - message: The message on its own.
  ///   - toolInput: The tool input on its own.
  public init(
    id: String, carryingSessionId: String, targetSessionId: String? = nil, title: String,
    detail: String, kind: DecisionKind, permissions: PermissionOptions = PermissionOptions(),
    phase: String? = nil, policyName: String? = nil, acceptsFeedback: Bool = false,
    answered: Bool = false, message: String? = nil, toolInput: String? = nil
  ) {
    self.id = id
    self.carryingSessionId = carryingSessionId
    self.targetSessionId = targetSessionId ?? carryingSessionId
    self.title = title
    self.detail = detail
    self.message = message
    self.toolInput = toolInput
    self.kind = kind
    self.permissions = permissions
    self.phase = phase
    self.policyName = policyName
    self.acceptsFeedback = acceptsFeedback
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
  /// Values for a form plus notes on fields that ``FormField/acceptsNotes``, keyed by field key.
  case formWithNotes(values: [String: ElicitationValue], notes: [String: String])
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
  /// Accept and apply every suggested update (``PermissionOptions/suggestions``).
  case approveSuggestions
  /// Approve the plan and switch to one of its ``PermissionOptions/planModes``.
  case approvePlanMode(mode: PermissionMode)
  /// Decline with feedback the agent receives, on a card that ``DecisionCard/acceptsFeedback``.
  /// Must not be blank.
  case declineWithFeedback(feedback: String)

  /// A short past-tense description, for the answered state and VoiceOver.
  public var summary: String {
    switch self {
    case .approve: "Approved"
    case .decline: "Rejected"
    case .cancel: "Dismissed"
    case .answer(let value): "Answered: \(value)"
    case .form, .formWithNotes: "Answers submitted"
    case .approveAllEdits: "Approved · all edits allowed"
    case .approveAutoMode: "Approved · auto mode"
    case .approveDirectories: "Approved for these directories"
    case .approveRemembering: "Approved and remembered"
    case .approveCommandPolicy: "Approved with the command policy"
    case .approvePersist(let mode):
      mode == .always ? "Always allowed" : "Approved for this session"
    case .approveSuggestions: "Approved with the suggested permissions"
    case .approvePlanMode(let mode):
      switch mode {
      case .auto: "Plan approved \u{00B7} auto mode"
      case .acceptEdits: "Plan approved \u{00B7} edits accepted"
      case .bypassPermissions: "Plan approved \u{00B7} permissions bypassed"
      case .default, .plan, .dontAsk: "Plan approved"
      }
    case .declineWithFeedback: "Rejected · reply sent to the agent"
    }
  }

  /// Whether the response changes approval behavior beyond this one request.
  public var changesStandingPermissions: Bool {
    switch self {
    case .approveAllEdits, .approveAutoMode, .approveDirectories, .approveRemembering,
      .approveCommandPolicy, .approvePersist, .approveSuggestions:
      true
    // Leaving plan mode for a mode that still asks before edits changes nothing standing.
    case .approvePlanMode(let mode):
      mode != .default && mode != .plan
    case .approve, .decline, .cancel, .answer, .form, .formWithNotes, .declineWithFeedback:
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
