import SwiftUI

extension ActivityKind {
  var systemImage: String {
    switch self {
    case .toolCall, .toolResult: "wrench.and.screwdriver"
    case .nativeTool: "sparkles"
    case .reasoning: "brain"
    case .compaction: "arrow.down.right.and.arrow.up.left"
    case .command: "command"
    case .terminal: "apple.terminal"
    case .routing: "arrow.triangle.branch"
    case .resource: "shippingbox"
    case .error: "exclamationmark.octagon"
    case .unknown: "questionmark.square.dashed"
    case .retry: "arrow.clockwise"
    case .file: "doc.badge.plus"
    case .policy: "hand.raised"
    case .clientTask: "laptopcomputer"
    case .browser: "globe"
    case .sidechat: "bubble.left.and.text.bubble.right"
    }
  }

  var displayName: String {
    switch self {
    case .toolCall: "Tool call"
    case .toolResult: "Tool result"
    case .nativeTool: "Native tool"
    case .reasoning: "Reasoning"
    case .compaction: "Compaction"
    case .command: "Command"
    case .terminal: "Terminal"
    case .routing: "Routing"
    case .resource: "Resource"
    case .error: "Error"
    case .unknown: "Unsupported item"
    case .retry: "Retry"
    case .file: "File"
    case .policy: "Policy"
    case .clientTask: "Client task"
    case .browser: "Browser"
    case .sidechat: "Side question"
    }
  }
}

/// A header that toggles a detail area, with an icon, a title, trailing accessories and a
/// rotating chevron.
struct ExpandableHeader<Accessory: View>: View {
  @Binding var isExpanded: Bool
  let systemImage: String
  var tint: ThemeColor = .secondary
  let title: String
  var subtitle: String?
  var monospacedSubtitle = false
  var isEnabled = true
  /// The toggle's accessibility identifier.
  var identifier: String?
  @ViewBuilder var accessory: Accessory
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if isEnabled {
      Button {
        withAnimation(reduceMotion ? nil : Theme.Motion.disclosure) { isExpanded.toggle() }
      } label: {
        row
      }
      .buttonStyle(.plain)
      .hoverHighlight()
      .accessibilityLabel(title)
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityHint("Shows details")
      .accessibilityIdentifier(identifier ?? "", isEnabled: identifier != nil)
    } else {
      row
        .accessibilityElement(children: .combine)
    }
  }

  private var row: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
      Image(systemName: systemImage)
        .foregroundStyle(tint)
        .frame(width: Theme.Control.icon)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        Text(title)
          .font(Theme.Typography.label)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        if isExpanded, let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(monospacedSubtitle ? Theme.codeFont : .caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      Spacer(minLength: 8)
      accessory
      if isEnabled {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .accessibilityHidden(true)
      }
    }
    .padding(.vertical, Theme.Spacing.small)
    .padding(.horizontal, Theme.Spacing.small)
    .contentShape(Rectangle())
  }
}

/// Status glyph for tool and activity rows.
struct ActivityStatusView: View {
  let isRunning: Bool
  let isFailure: Bool
  var status: String?

  var body: some View {
    if isRunning {
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("Running")
    } else if isFailure {
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(Theme.failure)
        .accessibilityLabel("Failed")
    } else if let status, ["cancelled", "canceled"].contains(status.lowercased()) {
      Image(systemName: "minus.circle")
        .foregroundStyle(.secondary)
        .accessibilityLabel("Cancelled")
    } else {
      Image(systemName: "checkmark.circle")
        .foregroundStyle(.tertiary)
        .accessibilityLabel("Completed")
    }
  }
}

/// Detail sections: code in a code block (or a diff when the text is one), prose as text.
struct DetailSectionsView: View {
  let sections: [DetailSection]
  let rowID: String
  var maxSections = 24

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      ForEach(sections.prefix(maxSections)) { section in
        VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
          HStack {
            Text(section.title)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .textCase(.uppercase)
            Spacer()
            if !section.isCode { CopyButton(text: section.text, label: "Copy \(section.title)") }
          }
          if section.isCode {
            if let diff = DiffSummary.parse(section.text) {
              DiffView(diff: diff)
            } else {
              CodeBlockView(code: section.text, language: nil, maxLines: 30)
            }
          } else {
            Text(verbatim: section.text)
              .font(.callout)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity-detail-\(rowID)-\(section.id)")
      }
      if sections.count > maxSections {
        Text("\(sections.count - maxSections) more sections are available in the web app.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
