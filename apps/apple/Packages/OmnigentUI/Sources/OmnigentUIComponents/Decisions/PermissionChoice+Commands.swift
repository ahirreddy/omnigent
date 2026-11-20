import Foundation

/// Codex command policy and Codex or Antigravity persistence, and how a long command prefix reads
/// in a menu.
extension PermissionChoice {
  /// What a menu item shows: one line on the Mac; the whole rule on iPhone and iPad, whose menus
  /// wrap and have no tooltip (as the web's touch layout).
  var menuTitle: String {
    #if os(macOS)
      shortLabel ?? label
    #else
      label
    #endif
  }

  /// A command prefix kept to one short line: whitespace runs (a heredoc's newlines included)
  /// become one space, and past `limit` characters it ends in an ellipsis.
  static func oneLinePrefix(_ prefix: String, limit: Int = 40) -> String {
    let line = prefix.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return line.count > limit ? String(line.prefix(limit - 1)) + "\u{2026}" : line
  }

  /// Codex command policy and Codex or Antigravity persistence.
  static func commandChoices(_ permissions: PermissionOptions) -> [Self] {
    var choices: [Self] = []
    if let policy = permissions.execPolicyAmendment, !policy.isEmpty {
      let prefix = policy.joined(separator: " ")
      let approve = "Approve and don\u{2019}t ask again for commands starting with "
      choices.append(
        Self(
          response: .approveCommandPolicy(policy: policy), label: approve + prefix,
          systemImage: "terminal", shortLabel: approve + oneLinePrefix(prefix)))
    }
    let pattern = permissions.antigravity?.alwaysAllowPattern
    if permissions.offersPersist(.session) {
      choices.append(
        Self(
          response: .approvePersist(mode: .session),
          label: pattern.map { "Allow commands starting with \($0) for this session" }
            ?? "Approve this tool for this session",
          systemImage: "clock",
          shortLabel: pattern.map {
            "Allow commands starting with \(oneLinePrefix($0)) for this session"
          }))
    }
    if permissions.offersPersist(.always) {
      choices.append(
        Self(
          response: .approvePersist(mode: .always),
          label: pattern.map { "Always allow commands starting with \($0)" }
            ?? "Always allow this tool",
          systemImage: "infinity",
          shortLabel: pattern.map { "Always allow commands starting with \(oneLinePrefix($0))" }))
    }
    return choices
  }
}
