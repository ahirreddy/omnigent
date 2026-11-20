import Foundation
import SwiftUI

/// A `sys_advise_models` call read as the web's `SmartRoutingCard` reads it: the dispatches the
/// orchestrator planned, from its arguments, and the model Smart Routing sized for each, from
/// its answer.
nonisolated struct SmartRoutingPlan: Hashable, Sendable {
  /// One planned dispatch and what was recommended for it.
  struct Task: Hashable, Sendable {
    let title: String
    /// The worker it goes to, as planned or as recommended.
    let agent: String
    /// The recommended model; `nil` while judging or when unsized.
    let model: String?
    let rationale: String
  }

  /// The tool's names.
  static let toolNames: Set<String> = ["sys_advise_models", "mcp__omnigent__sys_advise_models"]

  let tasks: [Task]
  /// The answer was a plan; `false` for an error string or no answer.
  let isSized: Bool
  /// How many tasks were sized.
  let sizedCount: Int

  /// Reads the plan from the call's arguments and output.
  static func read(arguments: String?, output: String?) -> Self {
    let planned = plannedTasks(arguments)
    let recommendations = output.flatMap(Self.recommendations)
    let rows =
      planned.isEmpty
      ? (recommendations ?? []).map { ($0.title, "") } : planned
    let byTitle = Dictionary(
      (recommendations ?? []).map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
    let tasks = rows.map { title, agent in
      let recommendation = byTitle[title]
      let recommendedAgent = recommendation?.agent ?? ""
      return Task(
        title: title, agent: recommendedAgent.isEmpty ? agent : recommendedAgent,
        model: recommendation?.model, rationale: recommendation?.rationale ?? "")
    }
    return Self(
      tasks: tasks, isSized: recommendations != nil, sizedCount: recommendations?.count ?? 0)
  }

  /// "haiku", "sonnet" or "opus" where the model is one, else its name without `databricks-`.
  static func shortModelName(_ model: String) -> String {
    let lower = model.lowercased()
    if let family = ["haiku", "sonnet", "opus"].first(where: { lower.contains($0) }) {
      return family
    }
    return lower.hasPrefix("databricks-") ? String(model.dropFirst("databricks-".count)) : model
  }

  private static func plannedTasks(_ arguments: String?) -> [(String, String)] {
    guard let arguments, let object = json(arguments) as? [String: Any],
      let tasks = object["tasks"] as? [Any]
    else { return [] }
    return tasks.compactMap { entry in
      guard let task = entry as? [String: Any], let title = task["title"] as? String,
        !title.isEmpty
      else { return nil }
      let agents = (task["agents"] as? [Any] ?? []).compactMap {
        ($0 as? [String: Any])?["agent"] as? String
      }
      return (title, agents.filter { !$0.isEmpty }.joined(separator: ", "))
    }
  }

  private struct Recommendation {
    let title: String
    let model: String
    let rationale: String
    let agent: String
  }

  // swiftlint:disable discouraged_optional_collection
  /// The sized recommendations; `nil` when the output isn't a plan (an `Error: …` string). A
  /// claude-sdk result wraps the plan's text in MCP content blocks.
  private static func recommendations(_ output: String) -> [Recommendation]? {
    var payload = json(output)
    if let blocks = payload as? [Any] {
      let text = blocks.lazy.compactMap { block -> String? in
        guard let block = block as? [String: Any], block["type"] as? String == "text" else {
          return nil
        }
        return block["text"] as? String
      }.first
      payload = text.flatMap(json)
    }
    guard let object = payload as? [String: Any], let list = object["recommendations"] as? [Any]
    else { return nil }
    return list.compactMap { entry in
      guard let item = entry as? [String: Any], let title = item["title"] as? String,
        !title.isEmpty, let model = item["model"] as? String, !model.isEmpty
      else { return nil }
      return Recommendation(
        title: title, model: model, rationale: item["rationale"] as? String ?? "",
        agent: item["agent"] as? String ?? "")
    }
  }

  // swiftlint:enable discouraged_optional_collection

  private static func json(_ text: String) -> Any? {
    text.data(using: .utf8).flatMap {
      try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed])
    }
  }
}

/// A Smart Routing plan as a card: each planned dispatch with its worker, the recommended
/// model and why, or the dispatcher's message when no plan came back; the raw answer is one
/// disclosure away.
struct SmartRoutingCardView: View {
  let plan: SmartRoutingPlan
  let isJudging: Bool
  let output: String?

  @State private var showsRaw = false

  private var taskNoun: String { plan.tasks.count == 1 ? "task" : "tasks" }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      header
      if !isJudging, !plan.isSized {
        Text(output ?? "No routing decision was recorded for this fan-out.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      } else {
        ForEach(Array(plan.tasks.enumerated()), id: \.offset) { _, task in row(task) }
      }
      if showsRaw, let output {
        CodeBlockView(code: output, language: "json", maxLines: 30)
      }
    }
    .padding(Theme.Spacing.small)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(cornerRadius: Theme.Radius.small)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("smart-routing-card")
  }

  private var header: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      Image(systemName: "brain").foregroundStyle(.secondary).accessibilityHidden(true)
      Text("Smart routing").fontWeight(.medium)
      if isJudging {
        Text("Weighing \(plan.tasks.count) \(taskNoun)\u{2026}").foregroundStyle(.secondary)
        ProgressView().controlSize(.mini)
      } else {
        Text(
          plan.isSized ? "\u{00B7} sized \(plan.sizedCount) \(taskNoun)" : "\u{00B7} unavailable"
        )
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if output != nil {
        Button {
          showsRaw.toggle()
        } label: {
          Image(systemName: showsRaw ? "chevron.down" : "chevron.right")
            .accessibilityLabel("Show raw routing response")
        }
        .buttonStyle(.borderless)
        .help("Show raw routing response")
      }
    }
    .font(.callout)
  }

  private func row(_ task: SmartRoutingPlan.Task) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: Theme.Spacing.small) {
        Text(task.title).font(.callout.monospaced()).lineLimit(1).truncationMode(.tail)
        if !task.agent.isEmpty {
          Text("\u{2192} \(task.agent)").font(.callout).foregroundStyle(.tertiary).lineLimit(1)
        }
        Spacer(minLength: Theme.Spacing.small)
        if let model = task.model {
          Text(SmartRoutingPlan.shortModelName(model))
            .font(.caption2.monospaced().weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .help(model)
        } else {
          Text(isJudging ? "Sizing\u{2026}" : "\u{2014}").font(.callout).foregroundStyle(.tertiary)
        }
      }
      if !task.rationale.isEmpty {
        Text(task.rationale).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
