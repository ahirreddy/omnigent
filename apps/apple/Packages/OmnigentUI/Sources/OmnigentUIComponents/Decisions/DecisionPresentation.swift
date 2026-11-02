import Foundation
public import SwiftUI

// What a decision card offers and how it reads in one line. Shared by the full card, the
// compact row, the dock and the iPhone sheet, so every surface offers the same actions.

/// An approval variant that changes standing permissions. Each one is confirmed first.
struct PermissionChoice: Hashable {
  let response: DecisionResponse
  /// Names the scope and duration exactly ("for this session", "always").
  let label: String
  let systemImage: String

  /// The widening choices `card` advertises, in the web's order. A plan review offers only
  /// auto mode; a directory scope replaces the mode and "don't ask again" choices, as on the web.
  static func choices(for card: DecisionCard) -> [Self] {
    let permissions = card.permissions
    if permissions.plan != nil {
      // The server switches a plan approved with `allow_all_edits` to auto mode, so both flags
      // mean the same thing here; offer one.
      let response: DecisionResponse? =
        permissions.allowAllEdits
        ? .approveAllEdits : (permissions.allowAutoMode ? .approveAutoMode : nil)
      return response.map {
        [
          Self(
            response: $0, label: "Approve and use auto mode for this session", systemImage: "bolt")
        ]
      } ?? []
    }
    return scopeChoices(permissions) + commandChoices(permissions)
  }

  /// Session modes, "don't ask again" and the directory scope.
  private static func scopeChoices(_ permissions: PermissionOptions) -> [Self] {
    let directories = permissions.permissionDirectories
    if !directories.isEmpty {
      let scope = directories.count == 1 ? directories[0] : "\(directories.count) directories"
      return [
        Self(
          response: .approveDirectories, label: "Approve and allow \(scope) for this session",
          systemImage: "folder.badge.plus")
      ]
    }
    var choices: [Self] = []
    if permissions.allowAllEdits {
      choices.append(
        Self(
          response: .approveAllEdits, label: "Approve and accept all edits for this session",
          systemImage: "pencil.and.list.clipboard"))
    }
    if permissions.allowAutoMode {
      choices.append(
        Self(
          response: .approveAutoMode, label: "Approve and use auto mode for this session",
          systemImage: "bolt"))
    }
    if let label = permissions.rememberLabel {
      choices.append(
        Self(
          response: .approveRemembering,
          label: "Approve and don\u{2019}t ask again for \(label) this session",
          systemImage: "checkmark.seal"))
    }
    return choices
  }

  /// Codex command policy and Codex or Antigravity persistence.
  private static func commandChoices(_ permissions: PermissionOptions) -> [Self] {
    var choices: [Self] = []
    if let policy = permissions.execPolicyAmendment, !policy.isEmpty {
      choices.append(
        Self(
          response: .approveCommandPolicy(policy: policy),
          label:
            "Approve and don\u{2019}t ask again for commands starting with \(policy.joined(separator: " "))",
          systemImage: "terminal"))
    }
    let pattern = permissions.antigravity?.alwaysAllowPattern
    if permissions.offersPersist(.session) {
      choices.append(
        Self(
          response: .approvePersist(mode: .session),
          label: pattern.map { "Allow commands starting with \($0) for this session" }
            ?? "Approve this tool for this session",
          systemImage: "clock"))
    }
    if permissions.offersPersist(.always) {
      choices.append(
        Self(
          response: .approvePersist(mode: .always),
          label: pattern.map { "Always allow commands starting with \($0)" }
            ?? "Always allow this tool",
          systemImage: "infinity"))
    }
    return choices
  }
}

/// Where one user action goes: straight to the server, or through the "Change approval
/// behavior?" confirmation first.
enum DecisionRoute: Hashable {
  /// Send as is.
  case send(DecisionResponse)
  /// Ask first; the response widens standing permissions.
  case confirm(DecisionResponse)

  init(_ response: DecisionResponse) {
    self = response.changesStandingPermissions ? .confirm(response) : .send(response)
  }
}

/// The actions a card offers, by kind. Whether they are enabled is the card's phase and access.
struct DecisionAvailability: Hashable {
  /// The primary button's title; `nil` when the card is not an approval.
  var approveTitle: String?
  /// Reject (decline) is offered.
  var canReject = false
  /// "Tell the agent instead" is offered: the reply rides on a decline.
  var canTellAgent = false
  /// "More approval options…", each confirmed first.
  var widening: [PermissionChoice] = []
  /// A choice card's answers.
  var options: [String] = []
  /// A form card's fields; empty for other kinds.
  var fields: [FormField] = []
  /// Cancel (dismiss without answering) is offered.
  var canDismiss = false
  /// The page an unsupported card can hand off to.
  var externalURL: String?

  init(_ card: DecisionCard) {
    switch card.kind {
    case .approval:
      approveTitle = card.permissions.plan == nil ? "Approve" : "Approve plan"
      canReject = true
      canTellAgent = card.acceptsFeedback
      widening = PermissionChoice.choices(for: card)
    case .choice(_, let options):
      self.options = options
      canDismiss = true
    case .form(let fields):
      self.fields = fields
      canDismiss = true
    case .unsupported(_, let externalURL):
      self.externalURL = externalURL
    }
  }

  /// The reply to send for "Tell the agent instead", or `nil` when there is nothing to send or
  /// the card cannot carry it.
  static func feedbackResponse(for card: DecisionCard, text: String) -> DecisionResponse? {
    guard card.acceptsFeedback, case .approval = card.kind else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : .declineWithFeedback(feedback: trimmed)
  }
}

/// A card in one line: "Run `cargo test -p omnigent-core auth`", "Edit 3 files", the question.
struct DecisionSummary: Hashable {
  /// Plain text before the code part.
  var lead: String
  /// A command or file name, shown monospaced.
  var code: String?
  /// What the full card shows beyond the summary, when short enough for one more line.
  var secondary: String?
  /// The compact row can answer the card: its payload is fully visible there.
  var answersInline: Bool

  /// The whole line as plain text, for VoiceOver and tests.
  var plain: String { [lead, code].compactMap(\.self).joined(separator: " ") }

  /// Longest command or detail the compact row shows in full.
  static let inlineLimit = 100
  /// Most and longest choice answers the compact row shows as buttons.
  static let inlineOptions = (count: 3, length: 28)

  init(lead: String, code: String? = nil, secondary: String? = nil, answersInline: Bool = false) {
    self.lead = lead
    self.code = code
    self.secondary = secondary
    self.answersInline = answersInline
  }

  init(_ card: DecisionCard) {
    let paragraphs = Self.paragraphs(card.detail)
    let lede = paragraphs.first.map(Self.plainText)
    if card.permissions.plan != nil {
      self.init(lead: "Review the plan")
      return
    }
    switch card.kind {
    case .approval:
      self = Self.approval(card, paragraphs: paragraphs, lede: lede)
    case .choice(_, let options):
      // A question with one short line of context ("Choose one focus.") shows it as the second
      // line, so the row still holds the whole request.
      let context = paragraphs.count == 2 ? paragraphs[1] : nil
      let shown = context.map { !$0.contains("\n") && $0.count <= Self.inlineLimit } ?? true
      let fits =
        paragraphs.count <= 2 && shown && options.count <= Self.inlineOptions.count
        && options.allSatisfy { $0.count <= Self.inlineOptions.length }
      self.init(
        lead: lede ?? "Choose an option", secondary: shown ? context.map(Self.plainText) : nil,
        answersInline: fits)
    case .form:
      self.init(lead: Self.isGeneric(card.title) ? (lede ?? "Questions") : card.title)
    case .unsupported:
      self.init(lead: lede ?? card.title)
    }
  }

  private static func approval(_ card: DecisionCard, paragraphs: [String], lede: String?) -> Self {
    let permissions = card.permissions
    if let command = permissions.command {
      let line = command.command
      return Self(
        lead: "Run", code: line, secondary: command.cwd.map { "in \($0)" },
        answersInline: !line.contains("\n") && line.count <= inlineLimit)
    }
    let files = permissions.files
    if files.count == 1, let file = files.first {
      return Self(
        lead: "Edit", code: URL(filePath: file.path).lastPathComponent, secondary: counts(file),
        answersInline: true)
    }
    if files.count > 1 { return Self(lead: "Edit \(files.count) files") }
    if let action = permissions.antigravity?.actionDescription {
      return Self(lead: action, answersInline: action.count <= inlineLimit)
    }
    let short = paragraphs.count <= 1 && (lede?.count ?? 0) <= inlineLimit
    // A named request ("Apply the sample design?") keeps its name; a one-paragraph detail still
    // shows in full as the second line.
    if !isGeneric(card.title) {
      return Self(lead: card.title, secondary: lede, answersInline: short)
    }
    return Self(lead: lede ?? "Approval requested", answersInline: short)
  }

  /// "+12 −3" for a file change, when counts are known. Zero counts are left out: a new file
  /// reads "+11", not "+11 −0".
  static func counts(_ file: DecisionFileChange) -> String? {
    let parts = [file.shownAdded.map { "+\($0)" }, file.shownRemoved.map { "\u{2212}\($0)" }]
      .compactMap(\.self)
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  /// The core's default titles, which say nothing about the request.
  static func isGeneric(_ title: String) -> Bool {
    ["Approval requested", "Response requested", "Review the plan", ""].contains(title)
  }

  /// The detail's paragraphs, blank ones dropped.
  static func paragraphs(_ text: String) -> [String] {
    text.components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  /// Inline Markdown emphasis and code marks removed, for a one-line summary.
  static func plainText(_ markdown: String) -> String {
    var text = markdown
    for mark in ["**", "__", "`"] { text = text.replacingOccurrences(of: mark, with: "") }
    return text.replacingOccurrences(of: "\n", with: " ")
  }
}

extension EnvironmentValues {
  /// Prepended to every identifier inside a decision card, so the same card shown in two places
  /// (inline in the transcript and pinned in the dock) has distinct identifiers in each.
  @Entry var decisionIDPrefix = ""
  /// The one card whose Approve answers Command-Return. Set by the dock (or a host showing a
  /// single focused request) so the shortcut never applies to two buttons at once.
  @Entry var decisionShortcutCardID: String?
  /// The dock opens expanded (the playground uses it to show both states).
  @Entry var decisionDockStartsExpanded = false
}

extension View {
  /// Lets the Approve button of the card with `cardID` answer Command-Return and show the hint.
  /// - Parameter cardID: The card, or `nil` for none.
  /// - Returns: The view.
  public func decisionApproveShortcut(_ cardID: String?) -> some View {
    environment(\.decisionShortcutCardID, cardID)
  }
}

extension DecisionFileChange {
  /// Lines added, when known and not zero.
  var shownAdded: Int? { added.flatMap { $0 == 0 ? nil : $0 } }
  /// Lines removed, when known and not zero.
  var shownRemoved: Int? { removed.flatMap { $0 == 0 ? nil : $0 } }
}
