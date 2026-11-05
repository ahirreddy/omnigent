import SwiftUI

extension ApprovalRisk {
  /// The chip's tint: neutral, then primary, then the theme's warning for full access.
  var tint: AnyShapeStyle {
    switch self {
    case .readOnly, .ask: AnyShapeStyle(.secondary)
    case .autoEdit, .autoApprove: AnyShapeStyle(.primary)
    case .fullAccess: AnyShapeStyle(Theme.warning)
    }
  }

  /// A short risk word for VoiceOver.
  var accessibilityDescription: String {
    switch self {
    case .readOnly: "read only"
    case .ask: "asks first"
    case .autoEdit: "edits without asking"
    case .autoApprove: "approves without asking"
    case .fullAccess: "full access, no approvals"
    }
  }
}

/// The approval-mode chip: a shield symbol tinted by risk and the mode's name (a state, never an
/// action). Single-choice menu; ⇧Tab in the editor cycles the switchable modes. It sits apart
/// from the host and sandbox, and from the model picker.
struct ApprovalModeChip: View {
  let modes: ApprovalModes
  let select: (@MainActor (ApprovalModeOption) -> Void)?
  var isCompact = false
  @Environment(\.composerLayoutStyle) private var layout

  private var risk: ApprovalRisk { modes.selected?.risk ?? .ask }
  private var name: String { modes.selected?.label ?? "Approvals" }

  var body: some View {
    Menu {
      Section(modes.title) {
        ForEach(modes.options) { option in
          Button {
            select?(option)
          } label: {
            Label {
              Text(option.label)
              if let detail = option.detail { Text(detail) }
            } icon: {
              Image(
                systemName: option.id == modes.selectedID ? "checkmark" : option.risk.systemImage)
            }
          }
          .disabled(!option.isSwitchable && option.id != modes.selectedID)
          .accessibilityIdentifier("composer-approval-mode-\(option.id)")
        }
      }
      Section {
        Text("Shift-Tab switches modes. The sandbox and model are separate.")
      }
    } label: {
      if layout == .card { footerLabel } else { label }
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .modifier(ComposerControlChrome())
    .disabled(select == nil)
    .help(help)
    .accessibilityLabel("Approval mode, \(name)")
    .accessibilityValue(modes.selected.map(\.risk.accessibilityDescription) ?? "not reported")
    .accessibilityHint("Shift-Tab switches modes")
    .accessibilityIdentifier("composer-approval-mode")
  }

  /// The Mac's row under the pill: the mode's name as plain text; full access keeps its warning
  /// symbol and color.
  private var footerLabel: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      if risk == .fullAccess {
        Image(systemName: risk.systemImage).accessibilityHidden(true)
      }
      Text(name).lineLimit(1)
    }
    .foregroundStyle(risk == .fullAccess ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.primary))
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  private var label: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      Image(systemName: risk.systemImage)
        .foregroundStyle(risk.tint)
        .accessibilityHidden(true)
      // Compact widths keep a one-word label: a bare glyph does not say which mode.
      Text(isCompact ? Self.shortName(name) : name)
        .lineLimit(1)
        // Its ideal width, capped on touch so one row fits.
        .frame(
          maxWidth: layout == .touch ? ComposerBarMetrics.modeWidth : nil, alignment: .leading
        )
        .fixedSize(horizontal: layout == .touch, vertical: false)
        .foregroundStyle(
          risk == .fullAccess ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.primary))
      Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .font(.callout)
    .accessibilityElement(children: .combine)
  }

  private var help: String {
    var parts = ["Approval mode: \(name)"]
    if let selected = modes.selected, let harness = selected.harnessLabel, harness != selected.label
    {
      parts.append("(\(harness))")
    }
    if let detail = modes.selected?.detail { parts.append("\u{2014} \(detail)") }
    return parts.joined(separator: " ") + ". Shift-Tab switches modes."
  }

  /// The first word: "Auto-edit", "Full", "Ask".
  static func shortName(_ name: String) -> String {
    name.split(separator: " ").first.map(String.init) ?? name
  }
}

/// The brief notice after ⇧Tab switches the mode: its symbol, name and what it allows. Announced
/// to VoiceOver; it fades on its own.
struct ApprovalModeHUD: View {
  let option: ApprovalModeOption

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      Image(systemName: option.risk.systemImage)
        .foregroundStyle(option.risk.tint)
        .accessibilityHidden(true)
      Text(option.label).font(.callout.weight(.semibold))
      if let detail = option.detail {
        Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.vertical, Theme.Spacing.small)
    .glassSurface(in: Capsule())
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("composer-approval-mode-hud")
  }
}
