public import SwiftUI

/// The label, tint and glyph for a harness id. Glyphs are SF Symbols and monograms, not brand
/// logos; brand vectors (MIT, `@lobehub/icons`) can replace the monogram later with the
/// attribution in `Reference/NativeLab/App/HarnessBranding-NOTICE.md`.
nonisolated public struct HarnessAppearance: Hashable, Sendable {
  /// A stable identifier, for example `codex` or `claude`.
  public let identifier: String
  /// The display label.
  public let label: String

  /// Resolves the appearance of a harness id or alias.
  /// - Parameter harness: The harness as sent, for example `codex-native`.
  public init(harness: String?) {
    let raw = harness?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let known: [KnownHarness] = [
      KnownHarness(prefixes: ["codex"], id: "codex", label: "Codex"),
      KnownHarness(prefixes: ["claude-sdk"], id: "claude-sdk", label: "Claude SDK"),
      KnownHarness(prefixes: ["claude"], id: "claude", label: "Claude Code"),
      KnownHarness(prefixes: ["cursor"], id: "cursor", label: "Cursor"),
      KnownHarness(prefixes: ["kiro"], id: "kiro", label: "Kiro"),
      KnownHarness(prefixes: ["opencode"], id: "opencode", label: "OpenCode"),
      KnownHarness(prefixes: ["kimi", "native-kimi"], id: "kimi", label: "Kimi"),
      KnownHarness(prefixes: ["antigravity", "agy"], id: "antigravity", label: "Antigravity"),
      KnownHarness(prefixes: ["goose", "native-goose"], id: "goose", label: "Goose"),
      KnownHarness(prefixes: ["pi"], id: "pi", label: "Pi"),
      KnownHarness(prefixes: ["hermes"], id: "hermes", label: "Hermes"),
      KnownHarness(prefixes: ["openai-agents"], id: "openai-agents", label: "OpenAI Agents"),
    ]
    if let match = known.first(where: { entry in
      entry.prefixes.contains { raw == $0 || raw.hasPrefix("\($0)-") }
    }) {
      identifier = match.id
      label = match.label
    } else {
      identifier = "fallback"
      label = raw.isEmpty ? "Agent" : raw.replacingOccurrences(of: "-", with: " ").capitalized
    }
  }

  private struct KnownHarness {
    let prefixes: [String]
    let id: String
    let label: String
  }

  /// The brand tint, or the primary color for monochrome marks.
  public var tint: Color {
    switch identifier {
    case "claude", "claude-sdk": Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    case "kiro": Color(red: 144 / 255, green: 70 / 255, blue: 1)
    case "codex", "openai-agents": Color(red: 0.06, green: 0.64, blue: 0.5)
    case "antigravity": Color(red: 0.26, green: 0.52, blue: 0.96)
    default: Color.secondary
    }
  }

  /// A one- or two-letter monogram.
  public var monogram: String {
    switch identifier {
    case "fallback": String(label.prefix(1)).uppercased()
    case "opencode": "OC"
    case "openai-agents": "OA"
    case "claude-sdk": "C"
    default: String(label.prefix(1)).uppercased()
    }
  }
}

/// A harness monogram in a rounded square, sized by the caller.
struct HarnessGlyph: View {
  let harness: String?
  var size: CGFloat = 18

  var body: some View {
    let appearance = HarnessAppearance(harness: harness)
    Text(verbatim: appearance.monogram)
      .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(
        appearance.identifier == "fallback" ? Color.gray : appearance.tint,
        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
      )
      .accessibilityElement()
      .accessibilityLabel(appearance.label)
      .accessibilityAddTraits(.isImage)
  }
}

/// How a turn or list status reads.
struct StatusPresentation: Hashable {
  let label: String
  let systemImage: String
  let tint: ThemeColor

  static func session(
    status: SessionListStatus, isReadOnly: Bool, failure: String?, pending: Int = 0
  ) -> Self {
    if pending > 0 || status == .needsResponse {
      return Self(label: "Needs response", systemImage: "hand.raised.fill", tint: Theme.attention)
    }
    if status == .running {
      return Self(label: "Running", systemImage: "circle.dotted.circle", tint: Theme.running)
    }
    if failure != nil {
      return Self(
        label: "Needs attention", systemImage: "exclamationmark.triangle.fill", tint: Theme.failure)
    }
    if isReadOnly {
      return Self(label: "Read only", systemImage: "eye", tint: Theme.secondary)
    }
    return Self(label: "Idle", systemImage: "checkmark.circle", tint: Theme.secondary)
  }

  static func turn(_ header: SessionHeader, pending: Int) -> Self {
    let status: SessionListStatus =
      switch header.status {
      case .idle: .idle
      case .running: .running
      case .needsResponse: .needsResponse
      }
    return session(
      status: status, isReadOnly: header.readOnly, failure: header.failureMessage,
      pending: pending)
  }
}
