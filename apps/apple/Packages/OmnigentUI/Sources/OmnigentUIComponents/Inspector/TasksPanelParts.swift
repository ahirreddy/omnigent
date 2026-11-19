import Foundation
import SwiftUI

/// The line under a task's name, with its lead set off as the web does.
struct TaskDetailText: View {
  let detail: TaskDetailLine

  var body: some View {
    switch detail {
    case .text(let text):
      Text(text)
    case .cantStart(let failed):
      Text("\(Text("Can't start").fontWeight(.medium)) \u{00B7} \(failed) failed")
    case .ready(let goal):
      Text(
        "\(Text("Ready").fontWeight(.medium).foregroundStyle(ThemeColor.controlTint))\(goal.map { " \u{00B7} \($0)" } ?? "")"
      )
    case .waitingForYou(let text):
      Text(
        "\(Text(TaskTimes.waitingForYou).fontWeight(.medium).foregroundStyle(Theme.brandAccent)) \u{00B7} \(text)"
      )
    case .started(let date, let text):
      TimelineView(.periodic(from: .now, by: 30)) { context in
        Text(TaskTimes.started(date, now: context.date) + (text.map { " \u{00B7} \($0)" } ?? ""))
      }
    }
  }
}

/// A running task's time so far, or when a finished one ended.
struct TaskMeta: View {
  let row: TaskRowState

  var body: some View {
    if let ended = row.endedAt {
      Text(TaskTimes.stamp(ended, now: .now))
        .help(ended.formatted(date: .abbreviated, time: .shortened))
    } else if let since = row.runningSince {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        Text(TaskTimes.duration(context.date.timeIntervalSince(since)))
      }
      .help("Started \(since.formatted(date: .abbreviated, time: .shortened))")
    }
  }
}

/// A task's statuses, oldest first, after what it waits on and its goal; a line marks each new
/// attempt.
struct TaskHistoryView: View {
  let row: TaskRowState

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      if !row.dependsOn.isEmpty {
        Text("After \(Text(TaskTimes.names(row.dependsOn)).foregroundStyle(ThemeColor.primary))")
          .foregroundStyle(Theme.secondary)
      }
      // The whole goal, whose start alone is the row's line.
      if let goal = row.goal {
        StepDescription(text: goal)
      }
      if row.history.isEmpty {
        Text("Nothing recorded yet.").foregroundStyle(Theme.secondary)
      } else {
        ForEach(row.history) { entry in
          if entry.restarted {
            HStack(spacing: Theme.Spacing.small) {
              Rectangle().fill(.separator).frame(height: 1)
              Text("Restarted").font(.caption2).foregroundStyle(Theme.secondary)
              Rectangle().fill(.separator).frame(height: 1)
            }
          }
          HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Circle()
              .fill(TaskStyle.segment(entry.state))
              .frame(width: 6, height: 6)
              .accessibilityHidden(true)
            Text(
              "\(Text(entry.label).foregroundStyle(ThemeColor.primary))\(entry.text.map { " \u{00B7} \($0)" } ?? "")"
            )
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.date.formatted(date: .omitted, time: .shortened))
              .monospacedDigit()
              .foregroundStyle(Theme.secondary)
          }
        }
      }
    }
    .font(.caption)
    .padding(Theme.Spacing.medium)
    .background(.quinary, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(row.name) history")
  }
}

/// A workflow step's whole description as Markdown (web `StepDescription`): what it reads, does
/// and produces, then the details a run needs, at about the size of the history around it.
struct StepDescription: View {
  let text: String
  @Environment(\.transcriptAppearance) private var appearance

  #if os(macOS)
    private static let size = 11.0
  #else
    private static let size = 13.0
  #endif

  var body: some View {
    var compact = appearance
    compact.chatFontSize = Self.size
    return MarkdownView(text)
      .environment(\.transcriptAppearance, compact)
      .environment(\.markdownOutputRendering, .rich)
      .foregroundStyle(Theme.secondary)
      .accessibilityIdentifier("tasks-step-description")
  }
}

/// A task's state as a small circle: numbered while it waits, filled once it ends.
struct TaskGlyph: View {
  let state: TaskState
  let number: Int

  var body: some View {
    ZStack {
      switch state {
      case .running:
        ProgressView().controlSize(.mini)
      case .needsInput:
        Image(systemName: "questionmark.bubble.fill").foregroundStyle(Theme.brandAccent)
      case .done:
        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
      case .failed:
        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.failure)
      case .stopped:
        Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
          .foregroundStyle(Theme.secondary)
      case .waiting, .ready:
        numbered
          .foregroundStyle(
            state == .ready ? AnyShapeStyle(ThemeColor.controlTint) : AnyShapeStyle(Theme.secondary)
          )
      }
    }
    .frame(width: 18, height: 18)
    .accessibilityHidden(true)
  }

  /// The task's number in a circle: the system's numbered symbol up to 50, then the digits in a
  /// ring drawn to match.
  @ViewBuilder private var numbered: some View {
    if (0...50).contains(number) {
      Image(systemName: "\(number).circle").accessibilityHidden(true)
    } else {
      Circle()
        .strokeBorder(.secondary)
        .overlay {
          Text("\(number)")
            .font(.caption2.weight(.medium).monospacedDigit())
            .minimumScaleFactor(0.5)
            .padding(2)
        }
    }
  }
}

/// The tab's colors and symbols, by state, as the web's `SEGMENT_COLORS` sets them; running and
/// ready take the window's accent.
nonisolated enum TaskStyle {
  static func segment(_ state: TaskState) -> ThemeColor {
    switch state {
    case .waiting: .system(Color.primary.opacity(0.1))
    case .ready: ThemeColor.controlTint.opacity(0.25)
    case .running: .controlTint
    case .stopped: .system(.gray)
    case .needsInput: .system(.pink)
    case .done: .system(.green)
    case .failed: .system(.red)
    }
  }

  static func tint(_ state: TaskState) -> ThemeColor {
    switch state {
    case .needsInput: .system(.pink)
    case .running, .ready: .controlTint
    case .failed: .system(.red)
    default: .system(.secondary)
    }
  }

  static func symbol(_ action: TaskMenuAction) -> String {
    switch action {
    case .stop: "stop.fill"
    case .retry: "arrow.counterclockwise"
    case .run, .resume, .proceed: "play.fill"
    }
  }
}

/// How the tab writes times, as the web's `relativeTime`, `formatDuration` and
/// `formatMessageTimestamp` do.
nonisolated enum TaskTimes {
  /// What a task waiting for the user says.
  static let waitingForYou = "Waiting for you"

  /// "just now", "3m ago".
  static func ago(_ date: Date, now: Date) -> String {
    let short = RelativeTime.short(date, now: now)
    return short == "now" ? "just now" : "\(short) ago"
  }

  /// "Started just now", "Started 3m ago".
  static func started(_ date: Date, now: Date) -> String {
    let short = RelativeTime.short(date, now: now)
    return short == "now" ? "Started just now" : "Started \(short) ago"
  }

  /// "8s", "1m 46s", "1h 2m".
  static func duration(_ seconds: TimeInterval) -> String {
    let whole = max(1, Int(seconds.rounded()))
    if whole < 60 { return "\(whole)s" }
    let minutes = whole / 60
    let rest = whole % 60
    if minutes < 60 { return rest > 0 ? "\(minutes)m \(rest)s" : "\(minutes)m" }
    let hours = minutes / 60
    let leftover = minutes % 60
    return leftover > 0 ? "\(hours)h \(leftover)m" : "\(hours)h"
  }

  /// "8:56 PM" today, "Nov 11, 8:56 PM" earlier this year, else with the year.
  static func stamp(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDate(date, inSameDayAs: now) { return time }
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    let day =
      sameYear
      ? date.formatted(.dateTime.month(.abbreviated).day())
      : date.formatted(.dateTime.month(.abbreviated).day().year())
    return "\(day), \(time)"
  }

  /// "A", "A and B", "A, B and C".
  static func names(_ names: [String]) -> String {
    guard let last = names.last else { return "" }
    return names.count == 1 ? last : "\(names.dropLast().joined(separator: ", ")) and \(last)"
  }
}
