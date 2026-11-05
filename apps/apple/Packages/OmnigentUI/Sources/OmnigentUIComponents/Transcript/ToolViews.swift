import OmnigentPlatform
import SwiftUI

/// Added and removed counts, green and red.
struct DiffCountsView: View {
  let added: Int
  let removed: Int

  var body: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      if added > 0 { Text(verbatim: "+\(added)").foregroundStyle(ThemeColor.diffAdded) }
      if removed > 0 {
        Text(verbatim: "\u{2212}\(removed)").foregroundStyle(ThemeColor.diffRemoved)
      }
    }
    .font(.caption.monospacedDigit().weight(.medium))
    .accessibilityElement()
    .accessibilityLabel("\(added) lines added, \(removed) removed")
  }
}

/// A unified diff with tinted added and removed lines, its files named basename first.
struct DiffView: View {
  let diff: DiffSummary
  var maxLines = 400
  /// Shows the folded lines; `nil` only names how many there are.
  var showAll: (() -> Void)?
  var codeFont = Theme.codeFont
  /// Long lines wrap instead of scrolling sideways (phones).
  var wrapsLines = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(
          diff.files.isEmpty
            ? "Diff" : diff.files.map { DecisionPath($0).name }.joined(separator: ", ")
        )
        .font(Theme.Typography.section)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(diff.files.joined(separator: "\n"))
        Spacer()
        DiffCountsView(added: diff.added, removed: diff.removed)
        CopyButton(
          text: diff.lines.map(\.text).joined(separator: "\n"), label: "Copy diff")
      }
      .padding(.leading, Theme.Spacing.medium)
      .padding(.trailing, Theme.Spacing.small)
      .padding(.vertical, Theme.Spacing.extraSmall)
      Divider().opacity(0.6)
      if wrapsLines {
        lines
      } else {
        ScrollView(.horizontal) { lines }
      }
      if diff.lines.count > maxLines {
        if let showAll {
          ShowAllButton(hidden: diff.lines.count - maxLines, action: showAll)
        } else {
          Text("\(diff.lines.count - maxLines) more lines")
            .font(.caption).foregroundStyle(.secondary).padding(Theme.Spacing.small)
        }
      }
    }
    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(.separator.opacity(0.6))
    }
  }

  private var lines: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(diff.lines.prefix(maxLines).enumerated()), id: \.offset) { _, line in
        Text(verbatim: line.text.isEmpty ? " " : line.text)
          .font(codeFont)
          .foregroundStyle(foreground(line.kind))
          .padding(.horizontal, Theme.Spacing.medium)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(background(line.kind))
      }
    }
    .textSelection(.enabled)
    .padding(.vertical, Theme.Spacing.small)
  }

  private func foreground(_ kind: DiffLineKind) -> ThemeColor {
    switch kind {
    case .added: ThemeColor.diffAdded
    case .removed: ThemeColor.diffRemoved
    case .header: ThemeColor.secondary
    case .context: ThemeColor.primary
    }
  }

  private func background(_ kind: DiffLineKind) -> ThemeColor {
    switch kind {
    case .added: ThemeColor.diffAdded.opacity(0.1)
    case .removed: ThemeColor.diffRemoved.opacity(0.1)
    case .header, .context: ThemeColor.system(.clear)
    }
  }
}

/// A run of tool calls. One call renders alone; several share a container whose header names
/// them and folds them once the run settles.
struct ToolGroupView: View, Equatable {
  let entries: [ToolEntry]
  // `nil` follows the run: expanded while a tool runs, folded once the run settles.
  // swiftlint:disable:next discouraged_optional_boolean
  @State private var expandedOverride: Bool?

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.entries == rhs.entries }

  private var isRunning: Bool { entries.contains(where: \.isRunning) }
  private var failures: Int { entries.count { $0.isFailure } }

  var body: some View {
    if entries.count == 1, let entry = entries.first {
      ToolRowView(entry: entry)
    } else {
      let expanded = Binding(
        get: { expandedOverride ?? isRunning },
        set: { expandedOverride = $0 })
      VStack(alignment: .leading, spacing: 0) {
        ExpandableHeader(
          isExpanded: expanded, systemImage: "wrench.and.screwdriver",
          title: groupTitle,
          identifier: entries.first.map { "tool-group-toggle-\($0.id)" }
        ) {
          // One status per row: running, else the failures, else done.
          if !isRunning, failures > 0 {
            Pill(text: "\(failures) failed", tint: Theme.failure)
          } else {
            ActivityStatusView(isRunning: isRunning, isFailure: false)
          }
        }
        if expanded.wrappedValue {
          Divider().padding(.leading, Theme.Spacing.section)
          VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
              ToolRowView(entry: entry)
            }
          }
          .padding(.leading, Theme.Spacing.large)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(entries.first.map { "tool-group-\($0.id)" } ?? "tool-group")
    }
  }

  private var groupTitle: String {
    isRunning
      ? "Working with \(entries.count) tools"
      : ToolRunSummary.text(for: entries.map { $0.primary?.activity?.title ?? "" })
  }

}

/// One tool call with its result.
struct ToolRowView: View {
  let entry: ToolEntry
  @State private var isExpanded = false

  private var activity: Activity? { entry.primary?.activity }

  /// The edit the call's arguments describe, else a diff in its output.
  private var diff: (summary: DiffSummary, isInput: Bool)? {
    let output = entry.result?.activity?.detail("output")
    if let call = entry.call?.activity, let arguments = call.detail("arguments"),
      let diff = ToolEditDiff.diff(tool: call.title, arguments: arguments, output: output)
    {
      return (diff, true)
    }
    return output.flatMap(DiffSummary.find(in:)).map { ($0, false) }
  }

  var body: some View {
    let found = diff
    let diff = found?.summary
    VStack(alignment: .leading, spacing: 0) {
      ExpandableHeader(
        isExpanded: $isExpanded,
        systemImage: activity?.kind.systemImage ?? "wrench.and.screwdriver",
        tint: entry.isFailure ? Theme.failure : .secondary,
        title: activity?.title ?? "Tool",
        subtitle: firstLine(entry.call?.activity?.summary ?? activity?.summary ?? ""),
        monospacedSubtitle: true, identifier: "tool-toggle-\(entry.id)"
      ) {
        HStack(spacing: Theme.Spacing.small) {
          if let diff { DiffCountsView(added: diff.added, removed: diff.removed) }
          ActivityStatusView(
            isRunning: entry.isRunning, isFailure: entry.isFailure, status: activity?.status)
        }
      }
      if isExpanded {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
          if let diff { DiffView(diff: diff) }
          // An edit's diff stands in for its raw arguments.
          if let call = entry.call?.activity, found?.isInput != true {
            DetailSectionsView(
              sections: call.details.isEmpty && !call.summary.isEmpty
                ? [DetailSection(id: "summary", title: "Input", text: call.summary, isCode: true)]
                : call.details,
              rowID: entry.call?.id ?? entry.id)
          }
          if let result = entry.result?.activity {
            DetailSectionsView(sections: result.details, rowID: entry.result?.id ?? entry.id)
          } else if entry.call != nil, !entry.isRunning {
            Text("No output recorded.").font(.caption).foregroundStyle(.secondary)
          }
          AttachmentStrip(
            attachments: (entry.call?.attachments ?? []) + (entry.result?.attachments ?? []))
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.medium)
        .padding(.top, Theme.Spacing.tiny)
      }
    }
    .contextMenu {
      Button("Copy Input", systemImage: "doc.on.doc") {
        Pasteboard.copy(entry.call?.activity?.summary ?? "")
      }
      .disabled(entry.call == nil)
      Button("Copy Output", systemImage: "doc.on.doc") {
        Pasteboard.copy(entry.result?.activity?.detail("output") ?? entry.result?.text ?? "")
      }
      .disabled(entry.result == nil)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("tool-\(entry.id)")
  }

  private func firstLine(_ text: String) -> String {
    text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
  }
}
