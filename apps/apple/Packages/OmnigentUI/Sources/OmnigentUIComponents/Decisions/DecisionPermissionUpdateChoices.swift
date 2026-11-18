// The widening choices a request's own permission updates add: the updates it suggests, and
// the modes approving its plan may switch to.

extension PermissionChoice {
  /// Approving the plan into `mode`. The plain approval already keeps asking before edits.
  static func planChoice(_ mode: PermissionMode) -> Self? {
    switch mode {
    case .auto:
      Self(
        response: .approvePlanMode(mode: mode),
        label: "Approve and use auto mode for this session", systemImage: "bolt")
    case .acceptEdits:
      Self(
        response: .approvePlanMode(mode: mode),
        label: "Approve and accept all edits for this session",
        systemImage: "pencil.and.list.clipboard")
    case .bypassPermissions:
      Self(
        response: .approvePlanMode(mode: mode),
        label: "Approve and bypass permissions for this session",
        systemImage: "exclamationmark.shield")
    case .default, .plan, .dontAsk:
      nil
    }
  }

  /// The request's suggested updates, applied together, each named.
  static func suggestionChoices(_ permissions: PermissionOptions) -> [Self] {
    let suggestions = permissions.suggestions
    guard !suggestions.isEmpty else { return [] }
    let labels = suggestions.map(\.label)
    let label =
      labels.count == 1
      ? "Approve and \(labels[0].prefix(1).lowercased())\(labels[0].dropFirst())"
      : "Approve and apply: \(labels.joined(separator: "; "))"
    return [
      Self(
        response: .approveSuggestions, label: label,
        systemImage: suggestions.contains(where: \.persists) ? "infinity" : "checkmark.seal")
    ]
  }
}
