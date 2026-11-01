import OmnigentPlatform
import SwiftUI

/// Added and removed counts, green and red.
struct DiffCountsView: View {
  let added: Int
  let removed: Int

  var body: some View {
    HStack(spacing: 4) {
      if added > 0 { Text(verbatim: "+\(added)").foregroundStyle(.green) }
      if removed > 0 { Text(verbatim: "\u{2212}\(removed)").foregroundStyle(.red) }
    }
    .font(.caption.monospacedDigit().weight(.medium))
    .accessibilityElement()
    .accessibilityLabel("\(added) lines added, \(removed) removed")
  }
}

/// A unified diff with tinted added and removed lines.
struct DiffView: View {
  let diff: DiffSummary
  var maxLines = 400

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(diff.files.isEmpty ? "Diff" : diff.files.joined(separator: ", "))
          .font(.caption.weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        DiffCountsView(added: diff.added, removed: diff.removed)
        CopyButton(
          text: diff.lines.map(\.text).joined(separator: "\n"), label: "Copy diff")
      }
      .padding(.leading, 12)
      .padding(.trailing, 6)
      .padding(.vertical, 4)
      Divider().opacity(0.6)
      ScrollView(.horizontal) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(diff.lines.prefix(maxLines).enumerated()), id: \.offset) { _, line in
            Text(verbatim: line.text.isEmpty ? " " : line.text)
              .font(Theme.codeFont)
              .foregroundStyle(foreground(line.kind))
              .padding(.horizontal, 12)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(background(line.kind))
          }
        }
        .textSelection(.enabled)
        .padding(.vertical, 6)
      }
      if diff.lines.count > maxLines {
        Text("\(diff.lines.count - maxLines) more lines")
          .font(.caption).foregroundStyle(.secondary).padding(8)
      }
    }
    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(.separator.opacity(0.6))
    }
  }

  private func foreground(_ kind: DiffLineKind) -> Color {
    switch kind {
    case .added: Color.green
    case .removed: Color.red
    case .header: Color.secondary
    case .context: Color.primary
    }
  }

  private func background(_ kind: DiffLineKind) -> Color {
    switch kind {
    case .added: Color.green.opacity(0.1)
    case .removed: Color.red.opacity(0.1)
    case .header, .context: Color.clear
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
        .cardSurface(cornerRadius: Theme.Radius.medium)
    } else {
      let expanded = Binding(
        get: { expandedOverride ?? isRunning },
        set: { expandedOverride = $0 })
      VStack(alignment: .leading, spacing: 0) {
        ExpandableHeader(
          isExpanded: expanded, systemImage: "wrench.and.screwdriver",
          title: groupTitle, subtitle: toolNames,
          identifier: entries.first.map { "tool-group-toggle-\($0.id)" }
        ) {
          HStack(spacing: 6) {
            if failures > 0 { Pill(text: "\(failures) failed", tint: Theme.failure) }
            ActivityStatusView(isRunning: isRunning, isFailure: false)
          }
        }
        if expanded.wrappedValue {
          Divider().padding(.leading, 32)
          VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
              ToolRowView(entry: entry)
            }
          }
          .padding(.leading, 16)
        }
      }
      .cardSurface(cornerRadius: Theme.Radius.medium)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(entries.first.map { "tool-group-\($0.id)" } ?? "tool-group")
    }
  }

  private var groupTitle: String {
    isRunning
      ? "Working with \(entries.count) tools"
      : ToolRunSummary.text(for: entries.map { $0.primary?.activity?.title ?? "" })
  }

  private var toolNames: String {
    var seen: [String] = []
    for entry in entries {
      let name = entry.primary?.activity?.title ?? "Tool"
      if !seen.contains(name) { seen.append(name) }
    }
    let shown = seen.prefix(4).joined(separator: ", ")
    return seen.count > 4 ? "\(shown), and \(seen.count - 4) more" : shown
  }
}

/// One tool call with its result.
struct ToolRowView: View {
  let entry: ToolEntry
  @State private var isExpanded = false

  private var activity: Activity? { entry.primary?.activity }

  private var diff: DiffSummary? {
    let texts = [
      entry.call?.activity?.detail("arguments"), entry.result?.activity?.detail("output"),
    ]
    return texts.lazy.compactMap { $0 }.compactMap(DiffSummary.find(in:)).first
  }

  var body: some View {
    let diff = diff
    VStack(alignment: .leading, spacing: 0) {
      ExpandableHeader(
        isExpanded: $isExpanded,
        systemImage: activity?.kind.systemImage ?? "wrench.and.screwdriver",
        tint: entry.isFailure ? Theme.failure : .secondary,
        title: activity?.title ?? "Tool",
        subtitle: firstLine(entry.call?.activity?.summary ?? activity?.summary ?? ""),
        monospacedSubtitle: true, identifier: "tool-toggle-\(entry.id)"
      ) {
        HStack(spacing: 6) {
          if let diff { DiffCountsView(added: diff.added, removed: diff.removed) }
          ActivityStatusView(
            isRunning: entry.isRunning, isFailure: entry.isFailure, status: activity?.status)
        }
      }
      if isExpanded {
        VStack(alignment: .leading, spacing: 10) {
          if let diff { DiffView(diff: diff) }
          if let call = entry.call?.activity {
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
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 2)
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
