import OmnigentWorkspaceUI
public import SwiftUI

extension EnvironmentValues {
  /// The server's `session_overview` feature: the toolbar's cost chip opens the session's
  /// overview, and agents show what they cost.
  @Entry public var offersSessionOverview = false
}

// `nil` (no such route on the server) differs from empty (nothing priced yet), as the core's.
// swiftlint:disable discouraged_optional_collection
/// Reads the cost tags of a session and its agents, by session id; `nil` when the server has
/// none to read.
public struct AgentCostSource {
  /// Reads the tags.
  public var read: @MainActor () async -> Result<[String: String]?, LogReadFailure>

  /// Creates a source.
  /// - Parameter read: Reads the tags.
  public init(read: @escaping @MainActor () async -> Result<[String: String]?, LogReadFailure>) {
    self.read = read
  }
}
// swiftlint:enable discouraged_optional_collection

/// The session's overview, as the core's usage section carries it: the session's cost, each
/// model's cost (most expensive first) and the tokens of all of them.
struct SessionOverviewReading: Equatable {
  struct ModelCost: Equatable, Identifiable {
    let model: String
    let cost: String
    var id: String { model }
  }

  var cost: String?
  var models: [ModelCost] = []
  var tokens: Int?

  init(_ section: EventSection?) {
    func detail(_ id: String) -> String? { section?.details.first { $0.id == id }?.text }
    cost = detail("overview_cost")
    models =
      detail("overview_models")?.split(separator: "\n").map { line in
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        return ModelCost(
          model: parts.first.map(String.init) ?? "",
          cost: parts.dropFirst().first.map(String.init) ?? "")
      } ?? []
    tokens = detail("overview_tokens").flatMap { Int($0) }
  }

  /// "12.4K", as the web's compact token count.
  static func tokens(_ count: Int) -> String {
    count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
  }
}

/// The toolbar's cost chip (the web's `SessionCostButton`): the session's cost, or "—" until
/// one is known; it opens the session's overview.
struct SessionCostChip: View {
  let state: ConversationViewState
  let costs: AgentCostSource?
  var changes: ChangesModel?
  @Environment(\.offersSessionOverview) private var offers
  @State private var isShown = false

  var body: some View {
    if offers {
      let overview = SessionOverviewReading(state.section("usage"))
      Button {
        isShown.toggle()
      } label: {
        Text(overview.cost ?? "\u{2014}").font(.callout.monospacedDigit())
      }
      .help(isShown ? "Hide session overview" : "Show session overview")
      .accessibilityLabel("\(overview.cost ?? "Unknown cost"), session overview")
      .accessibilityIdentifier("header-session-cost")
      .popover(isPresented: $isShown) {
        SessionOverviewView(state: state, costs: costs, changes: changes) { isShown = false }
      }
    }
  }
}

/// The session's overview (the web's `SessionOverview`): its cost, each model's cost, the
/// tokens, and its direct sub-agents with what each cost.
struct SessionOverviewView: View {
  let state: ConversationViewState
  let costs: AgentCostSource?
  /// The session's uncommitted changes; `nil` where it has no workspace.
  var changes: ChangesModel?
  let close: () -> Void
  @State private var tags: [String: String] = [:]
  /// Why the sub-agents' costs could not be read.
  @State private var tagsFailure: String?

  var body: some View {
    let overview = SessionOverviewReading(state.section("usage"))
    let children = state.sections.filter { $0.id.hasPrefix("child-") }
    Form {
      Section {
        LabeledContent("Session cost", value: overview.cost ?? "Unavailable")
          .accessibilityIdentifier("session-overview-cost")
        ForEach(overview.models) { model in
          LabeledContent {
            Text(model.cost).monospacedDigit()
          } label: {
            Text(model.model).lineLimit(1).truncationMode(.middle).help(model.model)
          }
        }
        if let tokens = overview.tokens {
          LabeledContent("Tokens", value: SessionOverviewReading.tokens(tokens))
        }
        SessionOverviewChangeRows(list: changes?.state.value)
      }
      if !children.isEmpty {
        Section {
          ForEach(children) { child in
            LabeledContent {
              if let tag = child.sessionId.flatMap({ tags[$0] }) { AgentCostTag(label: tag) }
            } label: {
              Text(child.title).lineLimit(1)
            }
          }
        } header: {
          Text("Sub-agents")
        } footer: {
          if let tagsFailure { Text("Costs unavailable: \(tagsFailure)") }
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 280, idealWidth: 300)
    .safeAreaInset(edge: .top, spacing: 0) { header }
    .task(id: overview.cost) { await readTags() }
    .task { if case .idle = changes?.state { await changes?.reload() } }
    .accessibilityIdentifier("session-overview")
  }

  private var header: some View {
    HStack {
      Text("Session overview").font(.headline)
      Spacer()
      Button("Hide session overview", systemImage: "xmark", action: close)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
    .padding([.horizontal, .top], Theme.Spacing.medium)
  }

  /// Reads the sub-agents' costs, again whenever the session's cost changes.
  private func readTags() async {
    guard let costs else { return }
    switch await costs.read() {
    case .success(let read):
      tags = read ?? [:]
      tagsFailure = nil
    case .failure(let failure):
      tagsFailure = failure.message
    }
  }
}

/// "Files changed" and "Lines" (the web's `SessionOverviewChanges`), while the workspace has
/// uncommitted changes; Lines only when the host counted some file's lines.
struct SessionOverviewChangeRows: View {
  let list: ChangesList?

  var body: some View {
    if let list, !list.files.isEmpty {
      LabeledContent("Files changed") { Text("\(list.files.count)").monospacedDigit() }
        .accessibilityIdentifier("session-overview-files")
      if list.files.contains(where: { $0.linesAdded != nil || $0.linesRemoved != nil }) {
        LabeledContent("Lines") {
          HStack(spacing: Theme.Spacing.extraSmall) {
            Text("+\(list.totals.linesAdded)").foregroundStyle(ThemeColor.diffAdded)
            Text("\u{2212}\(list.totals.linesRemoved)").foregroundStyle(ThemeColor.diffRemoved)
          }
          .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session-overview-lines")
      }
    }
  }
}

/// An agent's cost, as the web's `AgentCostTag`: small, monospaced and muted.
struct AgentCostTag: View {
  let label: String

  var body: some View {
    Text(label)
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.secondary)
      .help(label.hasPrefix("~") ? "Estimated cost" : "Cost")
      .accessibilityLabel(label.hasPrefix("~") ? "Estimated cost \(label)" : "Cost \(label)")
      .accessibilityIdentifier("subagent-cost")
  }
}
