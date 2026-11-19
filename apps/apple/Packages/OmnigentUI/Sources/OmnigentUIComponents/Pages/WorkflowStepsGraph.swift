import SwiftUI

/// A workflow's steps top to bottom by dependency (web `WorkflowStepsGraph`): steps that can run
/// at once share a row, each box shows its number, name and a line of its description, and arrows
/// join a step to those that wait for it. In a run, each box takes its state's glyph and tint, and
/// its menu offers the task's action. A box shows the whole step in a popover.
struct WorkflowStepsGraph: View {
  let graph: WorkflowGraphState
  var perform: (@MainActor (WorkflowStepState, TaskMenuAction) -> Void)?

  #if os(macOS)
    static let nodeWidth: CGFloat = 240
  #else
    static let nodeWidth: CGFloat = 220
  #endif
  static let columnGap: CGFloat = 24
  static let rowGap: CGFloat = 28
  static let goalHeight: CGFloat = 70
  static let nameHeight: CGFloat = 44

  var body: some View {
    let layout = GraphLayout(graph: graph)
    ScrollView([.horizontal, .vertical]) {
      ZStack(alignment: .topLeading) {
        edges(layout)
        ForEach(graph.steps) { step in
          WorkflowStepNode(step: step, total: graph.steps.count, perform: perform)
            .frame(width: Self.nodeWidth, height: layout.height(ofRow: step.row))
            .offset(x: layout.x(step), y: layout.y(ofRow: step.row))
        }
      }
      .frame(width: layout.width, height: layout.height, alignment: .topLeading)
      .padding(Theme.Spacing.large)
      .frame(maxWidth: .infinity)
    }
    .frame(height: min(layout.height + Theme.Spacing.large * 2, 520))
    .background(
      .quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: AutomationStyle.cardRadius)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AutomationStyle.cardRadius)
        .strokeBorder(.separator, lineWidth: 0.5)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Workflow steps")
    .accessibilityIdentifier("workflow-steps-graph")
  }

  /// The arrows, from the bottom of a step to the top of each that waits for it.
  private func edges(_ layout: GraphLayout) -> some View {
    Canvas { context, _ in
      let byID = Dictionary(
        graph.steps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      var heads: Set<String> = []
      for edge in graph.edges {
        guard let from = byID[edge.from], let to = byID[edge.to] else { continue }
        let start = CGPoint(
          x: layout.x(from) + Self.nodeWidth / 2,
          y: layout.y(ofRow: from.row) + layout.height(ofRow: from.row))
        let end = CGPoint(x: layout.x(to) + Self.nodeWidth / 2, y: layout.y(ofRow: to.row))
        var path = Path()
        path.move(to: start)
        let bend = max(12, (end.y - start.y) / 2)
        path.addCurve(
          to: end, control1: CGPoint(x: start.x, y: start.y + bend),
          control2: CGPoint(x: end.x, y: end.y - bend))
        let running = to.state == .running
        context.stroke(
          path, with: .color(running ? Color.accentColor : .secondary.opacity(0.55)),
          style: StrokeStyle(lineWidth: 1.5, dash: running ? [4, 3] : []))
        // Paths into one step share its arrowhead.
        if heads.insert(to.id).inserted {
          var head = Path()
          head.move(to: CGPoint(x: end.x - 4, y: end.y - 6))
          head.addLine(to: end)
          head.addLine(to: CGPoint(x: end.x + 4, y: end.y - 6))
          head.closeSubpath()
          context.fill(head, with: .color(.secondary.opacity(0.7)))
        }
      }
    }
    .frame(width: layout.width, height: layout.height)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Where each row and box sits: rows as tall as their tallest box.
private struct GraphLayout {
  let rowTops: [CGFloat]
  let rowHeights: [CGFloat]
  let width: CGFloat
  let height: CGFloat

  init(graph: WorkflowGraphState) {
    var heights = Array(repeating: WorkflowStepsGraph.nameHeight, count: max(graph.rows, 1))
    for step in graph.steps where step.goalPreview?.isEmpty == false {
      if heights.indices.contains(step.row) { heights[step.row] = WorkflowStepsGraph.goalHeight }
    }
    var tops: [CGFloat] = []
    var next: CGFloat = 0
    for height in heights {
      tops.append(next)
      next += height + WorkflowStepsGraph.rowGap
    }
    rowTops = tops
    rowHeights = heights
    let columns = CGFloat(max(graph.columns, 1))
    width =
      columns * WorkflowStepsGraph.nodeWidth + (columns - 1) * WorkflowStepsGraph.columnGap
    height = max(0, next - WorkflowStepsGraph.rowGap)
  }

  func x(_ step: WorkflowStepState) -> CGFloat {
    CGFloat(step.halfColumn) * (WorkflowStepsGraph.nodeWidth + WorkflowStepsGraph.columnGap) / 2
  }

  func y(ofRow row: Int) -> CGFloat { rowTops.indices.contains(row) ? rowTops[row] : 0 }

  func height(ofRow row: Int) -> CGFloat {
    rowHeights.indices.contains(row) ? rowHeights[row] : WorkflowStepsGraph.nameHeight
  }
}

/// One step's box: its glyph, name and a line of its description, tinted by where it stands in a
/// run. A click shows the whole step; its menu offers the task's action.
private struct WorkflowStepNode: View {
  let step: WorkflowStepState
  let total: Int
  let perform: (@MainActor (WorkflowStepState, TaskMenuAction) -> Void)?
  @State private var showsDetail = false

  var body: some View {
    Button {
      showsDetail = true
    } label: {
      HStack(alignment: .top, spacing: Theme.Spacing.small) {
        TaskGlyph(state: step.state ?? .waiting, number: step.number)
        VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
          Text(step.name).font(.callout.weight(.medium)).lineLimit(2)
            .multilineTextAlignment(.leading)
          if let preview = step.goalPreview, !preview.isEmpty {
            Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
              .multilineTextAlignment(.leading)
          }
        }
        Spacer(minLength: 0)
        if let action = step.action, let perform {
          Menu {
            Button(action.title, systemImage: TaskStyle.symbol(action.kind)) {
              perform(step, action.kind)
            }
          } label: {
            Image(systemName: "ellipsis").accessibilityLabel("Actions for \(step.name)")
          }
          .menuStyle(.button)
          .buttonStyle(.borderless)
          .menuIndicator(.hidden)
          .fixedSize()
        }
      }
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.small)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(.background, in: shape)
      .background(tint, in: shape)
      .overlay(shape.strokeBorder(border, style: borderStyle))
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .popover(isPresented: $showsDetail, arrowEdge: .bottom) { detail }
    .help(step.name)
    .accessibilityLabel("Task \(step.number) of \(total): \(step.name)")
    .accessibilityValue(step.state.map(Self.stateLabel) ?? "")
    .accessibilityIdentifier("workflow-step-\(step.id)")
  }

  private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

  private var tint: AnyShapeStyle {
    guard let state = step.state, state != .waiting, state != .ready else {
      return AnyShapeStyle(.clear)
    }
    return AnyShapeStyle(TaskStyle.segment(state).opacity(0.08))
  }

  private var border: AnyShapeStyle {
    switch step.state {
    case nil, .waiting: AnyShapeStyle(.separator)
    case .stopped: AnyShapeStyle(.secondary)
    case let state?: AnyShapeStyle(TaskStyle.segment(state).opacity(0.7))
    }
  }

  private var borderStyle: StrokeStyle {
    StrokeStyle(
      lineWidth: step.state == .running ? 1.5 : 1, dash: step.state == .stopped ? [3, 2] : [])
  }

  /// The whole step: "Task 2 of 5", its name, where it stands and its description.
  private var detail: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        Text("Task \(step.number) of \(total)").font(.caption).foregroundStyle(.secondary)
        Text(step.name).font(.headline).fixedSize(horizontal: false, vertical: true)
        if let state = step.state {
          Text(Self.stateLabel(state)).font(.caption.weight(.medium))
            .foregroundStyle(TaskStyle.tint(state))
        }
        if let goal = step.goal, !goal.isEmpty { StepDescription(text: goal) }
      }
      .padding(Theme.Spacing.large)
      .frame(width: 340, alignment: .leading)
    }
    .frame(maxHeight: 420)
    .accessibilityIdentifier("workflow-step-detail")
  }

  static func stateLabel(_ state: TaskState) -> String {
    switch state {
    case .waiting: "Not started"
    case .ready: "Ready"
    case .running: "Running"
    case .stopped: "Stopped"
    case .needsInput: TaskTimes.waitingForYou
    case .done: "Done"
    case .failed: "Failed"
    }
  }
}
