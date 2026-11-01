public import SwiftUI

/// The agent's plan (the `todos` section) as a collapsible checklist with progress. It sits
/// above the composer so the current step stays visible while the transcript scrolls.
public struct PlanAccordion: View {
  private let section: EventSection
  @State private var isExpanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.layoutWidth) private var layoutWidth

  /// Creates the accordion.
  /// - Parameter section: The `todos` section.
  public init(section: EventSection) {
    self.section = section
  }

  /// The accordion.
  public var body: some View {
    let todos = SectionReading.todos(section)
    let done = todos.count { $0.state == .completed }
    let current = todos.first { $0.state == .inProgress }
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { isExpanded.toggle() }
      } label: {
        HStack(spacing: 10) {
          ProgressRing(fraction: todos.isEmpty ? 0 : Double(done) / Double(todos.count))
          VStack(alignment: .leading, spacing: 1) {
            Text("Plan \u{00B7} \(done) of \(todos.count) done")
              .font(.callout.weight(.semibold))
            if let current, !isExpanded {
              Text(current.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          Spacer(minLength: 8)
          Image(systemName: "chevron.up")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Plan, \(done) of \(todos.count) done")
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityIdentifier("plan-accordion-toggle")
      if isExpanded {
        Divider()
        BoundedScrollView(maxHeight: 240) {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(todos) { todo in
              TodoRow(todo: todo)
            }
          }
          .padding(12)
        }
      }
    }
    .cardSurface(cornerRadius: Theme.Radius.large)
    .padding(.horizontal, layoutWidth == .compact ? 10 : 16)
    .padding(.top, 8)
    .frame(maxWidth: Theme.transcriptWidth)
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("plan-accordion")
  }
}

struct TodoRow: View {
  let todo: SectionReading.Todo

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Group {
        switch todo.state {
        case .completed:
          Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.running)
        case .inProgress:
          Image(systemName: "circle.dotted.circle").foregroundStyle(Theme.accent)
        case .pending:
          Image(systemName: "circle").foregroundStyle(.tertiary)
        }
      }
      .accessibilityHidden(true)
      Text(todo.text)
        .font(.callout)
        .strikethrough(todo.state == .completed, color: .secondary)
        .foregroundStyle(todo.state == .completed ? .secondary : .primary)
        .fontWeight(todo.state == .inProgress ? .medium : .regular)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(stateLabel)
  }

  private var stateLabel: String {
    switch todo.state {
    case .completed: "Done"
    case .inProgress: "In progress"
    case .pending: "Not started"
    }
  }
}

struct ProgressRing: View {
  let fraction: Double
  var size: CGFloat = 18

  var body: some View {
    ZStack {
      Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
      Circle()
        .trim(from: 0, to: fraction)
        .stroke(
          fraction >= 1 ? Theme.running : Theme.accent,
          style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}
