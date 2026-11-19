import Foundation
public import SwiftUI

/// The Tasks tab, as the web's `TasksPanel` shows it: the plan's name and where its tasks stand
/// over a strip of one segment per task, then a row per task with its state, its line, its time
/// and the menu its state offers. A plan's task opens its history; a task with a chat marker
/// scrolls the chat to it.
public struct TasksPanel: View {
  private let content: TasksPanelContent
  @State private var flashed: String?

  /// The tab.
  /// - Parameter content: What it shows and does.
  public init(content: TasksPanelContent) {
    self.content = content
  }

  /// The view.
  public var body: some View {
    Group {
      switch content.state {
      case .loading:
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Loading tasks")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        VStack(spacing: Theme.Spacing.small) {
          Text(message)
            .font(.callout)
            .foregroundStyle(Theme.secondary)
            .multilineTextAlignment(.center)
          Button("Retry", action: content.retry)
            .accessibilityIdentifier("tasks-retry")
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .empty:
        ContentUnavailableView {
          Label("No tasks yet", systemImage: "checklist")
        } description: {
          Text("Tasks show up here when the agent makes a to-do list.")
        }
        .accessibilityIdentifier("tasks-empty")
      case .loaded(let list):
        taskList(list)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("tasks-panel")
  }

  private func taskList(_ list: TaskListState) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
          TasksHeader(list: list, content: content) { jump(to: $0, proxy) }
          VStack(alignment: .leading, spacing: 0) {
            ForEach(list.rows) { row in
              TaskRowView(row: row, isFlashed: flashed == row.id, content: content)
                .id(row.id)
            }
          }
          .accessibilityElement(children: .contain)
          .accessibilityLabel("Tasks")
        }
        .padding(Theme.Spacing.medium)
      }
      .task(id: content.taskToShow) {
        guard let step = content.taskToShow else { return }
        content.shown()
        jump(to: step, proxy)
      }
    }
  }

  /// Scrolls `step`'s row into the middle and flashes it, as a segment or a chat marker asks.
  private func jump(to step: String, _ proxy: ScrollViewProxy) {
    withAnimation(Theme.Motion.disclosure) { proxy.scrollTo(step, anchor: .center) }
    flashed = step
    Task {
      do {
        try await Task.sleep(for: Theme.Timing.pause(.milliseconds(1_400)))
      } catch {
        return  // Another jump took over.
      }
      if flashed == step { flashed = nil }
    }
  }
}

extension EnvironmentValues {
  /// How task markers link to the Tasks tab; `nil` leaves them plain text.
  @Entry public var taskMarkerLinks: TaskMarkerLinks?
}

/// The tasks' summary: the plan's name, when it changed, its controls, the counts and the strip.
private struct TasksHeader: View {
  let list: TaskListState
  let content: TasksPanelContent
  let select: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      if list.planName != nil || list.updatedAt != nil {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
          if let name = list.planName {
            Text(name)
              .font(.headline)
              .lineLimit(2)
              .accessibilityAddTraits(.isHeader)
              .accessibilityIdentifier("tasks-plan-name")
          }
          Spacer(minLength: Theme.Spacing.small)
          if let updated = list.updatedAt {
            TimelineView(.periodic(from: .now, by: 30)) { context in
              Text("Updated \(TaskTimes.ago(updated, now: context.date))")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            }
          }
          controls
        }
      }
      summaryLine
      ProgressStrip(rows: list.rows, select: select)
    }
  }

  @ViewBuilder private var controls: some View {
    if list.isStopping {
      // Stop was taken; the run winds down before Continue shows.
      Label {
        Text("Stopping\u{2026}")
      } icon: {
        ProgressView().controlSize(.mini)
      }
      .labelStyle(.titleAndIcon)
      .font(.caption)
      .foregroundStyle(Theme.secondary)
      .help("Stopping the plan")
      .accessibilityIdentifier("tasks-plan-stopping")
    } else if list.canStop {
      Button("Stop", systemImage: "stop.fill", action: content.stop)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Stop the plan")
        .accessibilityIdentifier("tasks-plan-stop")
    } else if list.canContinue {
      Button("Continue", systemImage: "play.fill", action: content.continuePlan)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Continue the plan")
        .accessibilityIdentifier("tasks-plan-continue")
    }
  }

  private var summaryLine: some View {
    var pieces = [Text(list.summary).fontWeight(.medium)]
    for count in list.counts {
      pieces.append(Text(" \u{00B7} ").foregroundStyle(Theme.secondary))
      pieces.append(
        Text(count.text).fontWeight(.medium).foregroundStyle(TaskStyle.tint(count.state)))
    }
    if let paused = list.paused {
      pieces.append(Text(" \u{00B7} \(paused)").foregroundStyle(Theme.secondary))
    }
    return pieces.reduce(Text(verbatim: "")) { Text("\($0)\($1)") }
      .font(.callout)
      .accessibilityIdentifier("tasks-summary")
  }
}

/// One segment per task, colored by where it stands; a click goes to its row.
private struct ProgressStrip: View {
  let rows: [TaskRowState]
  let select: (String) -> Void

  var body: some View {
    HStack(spacing: rows.count > 16 ? 1 : 3) {
      ForEach(rows) { row in
        Button {
          select(row.id)
        } label: {
          Capsule()
            .fill(TaskStyle.segment(row.state))
            .frame(height: 6)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Task \(row.number) of \(rows.count): \(row.name) \u{00B7} \(row.stateLabel)")
        .accessibilityLabel("Task \(row.number), \(row.name): \(row.stateLabel)")
        .accessibilityIdentifier("tasks-segment-\(row.id)")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("tasks-progress")
  }
}

/// A task's row: its glyph, name and line, its time, its menu and, for a plan's task, its
/// history.
private struct TaskRowView: View {
  let row: TaskRowState
  let isFlashed: Bool
  let content: TasksPanelContent
  @State private var showsHistory = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: Theme.Spacing.extraSmall) {
        if let marker = row.markerRowID {
          Button {
            content.showInChat(marker)
          } label: {
            line
          }
          .buttonStyle(.plain)
          .help("Show in the chat")
          .accessibilityIdentifier("tasks-row-show-\(row.id)")
        } else {
          line
        }
        if let action = row.action {
          Menu {
            Button(action.title, systemImage: TaskStyle.symbol(action.kind)) {
              content.perform(action.kind, row)
            }
            .accessibilityIdentifier("tasks-row-\(action.kind.rawValue)-\(row.id)")
          } label: {
            Image(systemName: "ellipsis")
              .accessibilityLabel("Actions for \(row.name)")
          }
          .menuStyle(.button)
          .buttonStyle(.borderless)
          .menuIndicator(.hidden)
          .fixedSize()
          .accessibilityIdentifier("tasks-row-menu-\(row.id)")
        }
        if !row.isNative {
          Button {
            showsHistory.toggle()
          } label: {
            Image(systemName: "chevron.right")
              .rotationEffect(.degrees(showsHistory ? 90 : 0))
              .accessibilityLabel("\(showsHistory ? "Hide" : "Show") \(row.name) history")
          }
          .buttonStyle(.borderless)
          .accessibilityIdentifier("tasks-row-history-\(row.id)")
        }
      }
      .padding(.vertical, Theme.Spacing.extraSmall)
      .padding(.horizontal, Theme.Spacing.extraSmall)
      .background(tint, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
      .animation(Theme.Motion.disclosure, value: isFlashed)
      if showsHistory {
        TaskHistoryView(row: row)
          .padding(.leading, 30)
          .padding(.bottom, Theme.Spacing.small)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("tasks-row-\(row.id)")
    .accessibilityValue(row.stateLabel)
  }

  private var tint: ThemeColor {
    if isFlashed { return ThemeColor.controlTint.opacity(0.14) }
    switch row.state {
    case .running: return ThemeColor.controlTint.opacity(0.06)
    case .needsInput: return ThemeColor.system(.pink).opacity(0.06)
    default: return .system(.clear)
    }
  }

  private var line: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.medium) {
      TaskGlyph(state: row.state, number: row.number)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.name)
          .font(.callout.weight(emphasized ? .medium : .regular))
          .foregroundStyle(row.state == .waiting ? Theme.secondary : ThemeColor.primary)
          .fixedSize(horizontal: false, vertical: true)
        if let detail = row.detail {
          TaskDetailText(detail: detail)
            .font(.caption)
            .foregroundStyle(Theme.secondary)
            .lineLimit(3)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      TaskMeta(row: row)
        .font(.caption.monospacedDigit())
        .foregroundStyle(
          row.state == .running
            ? AnyShapeStyle(ThemeColor.controlTint) : AnyShapeStyle(Theme.secondary)
        )
        .padding(.top, 2)
    }
    .contentShape(Rectangle())
  }

  private var emphasized: Bool { [.running, .needsInput, .failed].contains(row.state) }
}
