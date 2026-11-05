import OmnigentPlatform
import SwiftUI

/// Every non-tool activity row.
struct ActivityRowView: View, Equatable {
  let row: Row

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row }

  var body: some View {
    if let activity = row.activity {
      switch activity.kind {
      case .reasoning: ReasoningRowView(row: row, activity: activity)
      case .terminal: TerminalRowView(row: row, activity: activity)
      case .error: ErrorRowView(row: row, activity: activity)
      case .retry: RetryRowView(row: row, activity: activity)
      case .compaction: CompactionRowView(row: row, activity: activity)
      case .sidechat: SidechatRowView(row: row, activity: activity)
      case .unknown: UnknownRowView(row: row, activity: activity)
      case .routing, .command, .resource, .file, .policy, .clientTask, .browser, .toolCall,
        .toolResult, .nativeTool:
        GenericActivityRowView(row: row, activity: activity)
      }
    } else {
      UnknownRowView(
        row: row,
        activity: Activity(kind: .unknown, title: "Activity", summary: row.text))
    }
  }
}

private struct TerminalRowView: View {
  let row: Row
  let activity: Activity
  @State private var isExpanded = false

  private var input: String? { activity.detail("input") }
  private var stdout: String? { activity.detail("stdout") }
  private var stderr: String? { activity.detail("stderr") }
  private var hasOutput: Bool { stdout?.isEmpty == false || stderr?.isEmpty == false }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if hasOutput {
        Button {
          isExpanded.toggle()
        } label: {
          terminalHeader
        }
        .buttonStyle(.plain)
        .accessibilityLabel(input.map { "Terminal command \($0)" } ?? "Terminal output")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("terminal-toggle-\(row.id)")
      } else {
        terminalHeader
          .accessibilityElement(children: .combine)
      }
      if isExpanded {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          if let stdout, !stdout.isEmpty { terminalText(stdout, color: .primary) }
          if let stderr, !stderr.isEmpty { terminalText(stderr, color: .red) }
          Label("Recorded output. Nothing runs on this device.", systemImage: "info.circle")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.medium)
      }
    }
    .background(
      Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.medium)
    )
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(.separator.opacity(0.5))
    }
    .contextMenu {
      if let input { Button("Copy Command", systemImage: "doc.on.doc") { Pasteboard.copy(input) } }
      if let stdout { Button("Copy Output", systemImage: "doc.on.doc") { Pasteboard.copy(stdout) } }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("terminal-\(row.id)")
  }

  private var terminalHeader: some View {
    HStack(spacing: Theme.Spacing.small) {
      Image(systemName: "apple.terminal")
        .foregroundStyle(.green)
        .accessibilityHidden(true)
      if let input, !input.isEmpty {
        Text("\(Text(verbatim: "$").foregroundStyle(.green).bold()) \(input)")
          .font(Theme.codeFont)
          .lineLimit(1)
      } else {
        Text(hasOutput ? "Terminal output" : "Terminal (no output)")
          .font(Theme.codeFont)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if row.isStreaming { ProgressView().controlSize(.small) }
      if hasOutput {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.vertical, 7)
    .contentShape(Rectangle())
  }

  private func terminalText(_ text: String, color: Color) -> some View {
    ScrollView(.horizontal) {
      Text(verbatim: text)
        .font(Theme.codeFont)
        .foregroundStyle(color)
        .textSelection(.enabled)
        .fixedSize(horizontal: true, vertical: true)
    }
  }
}

extension FailureRecovery {
  /// The error row's recovery button, in both transcript styles.
  var title: String { self == .continue ? "Retry" : "Resume" }
  var help: String {
    self == .continue ? "Continue the turn from where it stopped" : "Restart the agent and continue"
  }
}

private struct ErrorRowView: View {
  let row: Row
  let activity: Activity
  @State private var isExpanded = false
  @Environment(\.conversationActions) private var actions

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
        Image(systemName: "exclamationmark.octagon.fill")
          .foregroundStyle(Theme.failure)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
          Text(activity.title).font(.callout.weight(.semibold))
          Text(activity.summary)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        if let recovery = activity.recovery, let retry = actions.retryFailedTurn {
          Button(recovery.title) { retry(row) }
            .buttonStyle(.bordered)
            .help(recovery.help)
            .accessibilityIdentifier("error-retry-\(row.id)")
        }
        CopyButton(text: row.text.isEmpty ? activity.summary : row.text, label: "Copy error")
      }
      if !activity.details.isEmpty {
        DisclosureGroup("Details", isExpanded: $isExpanded) {
          DetailSectionsView(sections: activity.details, rowID: row.id)
            .padding(.top, Theme.Spacing.small)
        }
        .font(.caption)
      }
    }
    .padding(Theme.Spacing.medium)
    .cardSurface(
      cornerRadius: Theme.Radius.medium, tint: Theme.failure, stroke: Theme.failure.opacity(0.35)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Error: \(activity.summary)")
    .accessibilityIdentifier("error-\(row.id)")
  }
}

private struct RetryRowView: View {
  let row: Row
  let activity: Activity

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
      // The system spinner animates in the render server; a symbol effect redraws every frame.
      if row.isStreaming {
        ProgressView().controlSize(.small).accessibilityHidden(true)
      } else {
        Image(systemName: "arrow.clockwise")
          .foregroundStyle(Theme.warning)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        Text(activity.title).font(Theme.Typography.label)
        if !activity.summary.isEmpty {
          Text(activity.summary).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.horizontal, Theme.Spacing.small)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("retry-\(row.id)")
  }
}

private struct CompactionRowView: View {
  let row: Row
  let activity: Activity
  @State private var isExpanded = false

  var body: some View {
    VStack(spacing: Theme.Spacing.small) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: Theme.Spacing.medium) {
          line
          Label(activity.title, systemImage: "arrow.down.right.and.arrow.up.left")
            .font(Theme.Typography.section)
            .foregroundStyle(.secondary)
            .fixedSize()
          line
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityIdentifier("compaction-toggle-\(row.id)")
      if isExpanded {
        DetailSectionsView(sections: activity.details, rowID: row.id)
          .padding(Theme.Spacing.medium)
          .cardSurface(cornerRadius: Theme.Radius.medium)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("compaction-\(row.id)")
  }

  private var line: some View {
    Rectangle().fill(.separator).frame(height: 0.5)
  }
}

private struct SidechatRowView: View {
  let row: Row
  let activity: Activity
  @Environment(\.conversationActions) private var actions

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      HStack {
        Label("Side question", systemImage: "bubble.left.and.text.bubble.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        if let openSideChat = actions.openSideChat {
          Button("Open in Tab", systemImage: "rectangle.portrait.and.arrow.right") {
            openSideChat(row)
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help("Open this side question in its own tab")
          .accessibilityIdentifier("sidechat-open-tab-\(row.id)")
        }
      }
      if let question = activity.detail("question") {
        Text(verbatim: question)
          .font(Theme.Typography.label)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let answer = activity.detail("answer") {
        MarkdownView(answer).font(.callout)
      } else if !activity.summary.isEmpty {
        Text(activity.summary).font(.callout).foregroundStyle(.secondary)
      }
    }
    .padding(Theme.Spacing.medium)
    .overlay(alignment: .leading) {
      Rectangle().fill(ThemeColor.border).frame(width: 3)
    }
    .cardSurface(cornerRadius: Theme.Radius.medium)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("sidechat-\(row.id)")
  }
}

private struct UnknownRowView: View {
  let row: Row
  let activity: Activity
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ExpandableHeader(
        isExpanded: $isExpanded, systemImage: "questionmark.square.dashed",
        title: activity.title.isEmpty ? "Unsupported item" : activity.title,
        subtitle: activity.summary.isEmpty
          ? "This item type is not supported in the app yet." : activity.summary,
        isEnabled: !activity.details.isEmpty, identifier: "unknown-toggle-\(row.id)"
      ) {
        Pill(text: "Unsupported")
      }
      if isExpanded {
        DetailSectionsView(sections: activity.details, rowID: row.id)
          .padding(.horizontal, Theme.Spacing.medium)
          .padding(.bottom, Theme.Spacing.medium)
      }
    }
    .background {
      RoundedRectangle(cornerRadius: Theme.Radius.medium)
        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        .foregroundStyle(.tertiary)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("unknown-\(row.id)")
  }
}

private struct GenericActivityRowView: View {
  let row: Row
  let activity: Activity
  @State private var isExpanded = false

  private var tint: ThemeColor {
    if activity.isFailure { return Theme.failure }
    switch activity.kind {
    case .policy: return Theme.warning
    case .routing: return .system(.purple)
    default: return Theme.secondary
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ExpandableHeader(
        isExpanded: $isExpanded, systemImage: activity.kind.systemImage, tint: tint,
        title: activity.title, subtitle: activity.summary,
        monospacedSubtitle: activity.kind == .command,
        isEnabled: !activity.details.isEmpty, identifier: "activity-toggle-\(row.id)"
      ) {
        HStack(spacing: Theme.Spacing.small) {
          if let status = activity.status, !status.isEmpty, !activity.isFailure {
            Text(status.replacingOccurrences(of: "_", with: " ").capitalized)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if activity.isFailure || row.isStreaming {
            ActivityStatusView(isRunning: row.isStreaming, isFailure: activity.isFailure)
          }
        }
      }
      if isExpanded {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          if [.browser, .clientTask].contains(activity.kind) {
            Label(
              "Recorded activity only. Nothing runs on this device.", systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          DetailSectionsView(sections: activity.details, rowID: row.id)
          AttachmentStrip(attachments: row.attachments)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.medium)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("activity-\(row.id)")
  }
}
