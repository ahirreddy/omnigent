import OmnigentPlatform
public import SwiftUI

/// The session inspector: configuration, usage, plan, viewers, changed files, subagents,
/// environment, other sections the core reports, and the lifecycle history.
public struct SessionInspectorView: View {
  private let state: ConversationViewState
  private let actions: ConversationActions
  @State private var showsLifecycle = false

  /// Creates the inspector.
  /// - Parameters:
  ///   - state: The conversation.
  ///   - actions: Host actions (`openSession` for subagents).
  public init(state: ConversationViewState, actions: ConversationActions = ConversationActions()) {
    self.state = state
    self.actions = actions
  }

  private static let knownPrefixes = ["child-", "files-", "resource-"]
  private static let knownIDs: Set<String> = [
    "status", "collaboration", "permission", "approval", "usage", "todos", "presence",
    "superseded", "sandbox", "mcp", "terminal-pending",
  ]

  /// The inspector.
  public var body: some View {
    Form {
      sessionSection
      if let usage = state.section("usage") { usageSection(usage) }
      if let todos = state.section("todos") {
        Section("Plan") {
          ForEach(SectionReading.todos(todos)) { TodoRow(todo: $0) }
        }
      }
      if let presence = state.section("presence") {
        Section("Viewers") {
          ForEach(SectionReading.viewers(presence)) { viewer in
            LabeledContent(viewer.name) {
              Text(viewer.isIdle ? "Idle" : "Active")
                .foregroundStyle(viewer.isIdle ? .secondary : Theme.running)
            }
          }
        }
      }
      changedFilesSections
      subagentSection
      environmentSection
      otherSections
      lifecycleSection
    }
    .formStyle(.grouped)
    .environment(\.conversationActions, actions)
    .accessibilityIdentifier("session-inspector")
  }

  private var sessionSection: some View {
    let header = state.header
    let settings = header.settings
    return Section("Session") {
      LabeledContent("Status") {
        let status = StatusPresentation.turn(header, pending: state.pendingDecisions.count)
        Label(status.label, systemImage: status.systemImage).foregroundStyle(status.tint)
      }
      if let settings {
        LabeledContent("Harness") {
          HStack(spacing: 6) {
            HarnessGlyph(harness: settings.harness, size: 16)
            Text(HarnessAppearance(harness: settings.harness).label)
          }
        }
        LabeledContent("Model", value: settings.modelLabel)
        LabeledContent("Reasoning", value: reported(settings.reasoningEffort))
        if let routing = settings.routingMode {
          LabeledContent("Routing", value: routing.capitalized)
        }
        LabeledContent("Host") {
          Label(
            settings.hostOnline == true
              ? "Online" : settings.hostOnline == false ? "Offline" : "Unknown",
            systemImage: "circle.fill"
          )
          .labelStyle(StatusDotLabelStyle(color: dotColor(settings.hostOnline)))
        }
        LabeledContent("Runner") {
          Label(runnerLabel(settings), systemImage: "circle.fill")
            .labelStyle(StatusDotLabelStyle(color: dotColor(settings.runnerOnline)))
        }
      }
      ForEach(["permission", "approval", "collaboration"], id: \.self) { id in
        if let section = state.section(id) { LabeledContent(section.title, value: section.summary) }
      }
      if let failure = header.failureMessage {
        LabeledContent("Last failure") {
          Text(failure).foregroundStyle(Theme.failure).textSelection(.enabled)
        }
      }
      LabeledContent("Session ID") {
        HStack(spacing: 4) {
          Text(header.id).font(Theme.codeFont).lineLimit(1).truncationMode(.middle)
          CopyButton(text: header.id, label: "Copy session ID")
        }
      }
    }
  }

  private func usageSection(_ section: EventSection) -> some View {
    let usage = SectionReading.usage(section)
    return Section("Usage") {
      if let fraction = usage.fraction {
        VStack(alignment: .leading, spacing: 4) {
          ProgressView(value: fraction)
            .tint(fraction > 0.85 ? Theme.warning : Theme.accent)
          Text(
            "\(usage.contextTokens?.formatted() ?? "?") of \(usage.contextWindow?.formatted() ?? "?") context tokens"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      } else if let tokens = usage.contextTokens {
        LabeledContent("Context tokens", value: tokens.formatted())
      }
      if let cost = usage.totalCost {
        LabeledContent("Cost", value: cost.formatted(.currency(code: "USD")))
      }
      ForEach(usage.byModel, id: \.self) { line in
        Text(line).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
    }
  }

  @ViewBuilder private var changedFilesSections: some View {
    ForEach(state.sections.filter { $0.id.hasPrefix("files-") }) { section in
      Section {
        let files = SectionReading.changedFiles(section)
        if files.isEmpty {
          Text(section.summary).foregroundStyle(.secondary)
        }
        ForEach(files) { file in
          HStack(spacing: 8) {
            Text(file.letter)
              .font(.caption.monospaced().weight(.bold))
              .foregroundStyle(letterColor(file.letter))
              .frame(width: 14)
            Text(URL(filePath: file.path).lastPathComponent)
              .lineLimit(1)
            Text(URL(filePath: file.path).deletingLastPathComponent().relativePath)
              .font(.caption)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .truncationMode(.head)
          }
          .help(file.path)
          .contextMenu {
            Button("Copy Path", systemImage: "doc.on.doc") { Pasteboard.copy(file.path) }
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(file.path), \(file.status)")
        }
      } header: {
        Text("Changed Files")
      } footer: {
        if !SectionReading.changedFiles(section).isEmpty { Text(section.summary) }
      }
    }
  }

  @ViewBuilder private var subagentSection: some View {
    let children = state.sections.filter { $0.id.hasPrefix("child-") }
    if !children.isEmpty {
      Section("Subagents") {
        ForEach(children) { child in
          Button {
            if let id = child.sessionId { actions.openSession?(id) }
          } label: {
            LabeledContent {
              Text(child.summary).foregroundStyle(.secondary)
            } label: {
              Label(child.title, systemImage: "arrow.triangle.branch")
            }
          }
          .buttonStyle(.plain)
          .disabled(actions.openSession == nil)
          .accessibilityHint("Opens the subagent session")
        }
      }
    }
  }

  @ViewBuilder private var environmentSection: some View {
    let environment = state.sections.filter {
      ["sandbox", "mcp", "terminal-pending"].contains($0.id) || $0.id.hasPrefix("resource-")
    }
    if !environment.isEmpty {
      Section("Environment") {
        ForEach(environment) { section in
          SectionDisclosure(section: section)
        }
      }
    }
  }

  @ViewBuilder private var otherSections: some View {
    let others = state.sections.filter { section in
      !Self.knownIDs.contains(section.id)
        && !Self.knownPrefixes.contains { section.id.hasPrefix($0) }
    }
    if !others.isEmpty {
      Section("Other") {
        ForEach(others) { SectionDisclosure(section: $0) }
      }
    }
  }

  @ViewBuilder private var lifecycleSection: some View {
    let rows = state.lifecycleRows
    if !rows.isEmpty {
      Section {
        DisclosureGroup("Lifecycle history (\(rows.count))", isExpanded: $showsLifecycle) {
          ForEach(rows.reversed()) { row in
            ActivityRowView(row: row)
          }
        }
      }
    }
  }

  private func reported(_ value: ReportedValue) -> String {
    switch value {
    case .notReported: "Not reported"
    case .harnessDefault: "Harness default"
    case .value(let value): value.capitalized
    }
  }

  private func runnerLabel(_ settings: SessionSettings) -> String {
    if settings.runnerBound == false { return "Not bound" }
    switch settings.runnerOnline {
    case true?: return "Online"
    case false?: return "Offline"
    case nil: return "Unknown"
    }
  }

  // `online` mirrors the core's `Option<bool>`; `nil` is "not reported".
  // swiftlint:disable:next discouraged_optional_boolean
  private func dotColor(_ online: Bool?) -> ThemeColor {
    switch online {
    case true?: Theme.running
    case false?: Theme.failure
    case nil: Theme.secondary
    }
  }

  private func letterColor(_ letter: String) -> Color {
    switch letter {
    case "A": .green
    case "D": .red
    case "R": .purple
    default: .orange
    }
  }
}

private struct StatusDotLabelStyle: LabelStyle {
  let color: ThemeColor

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 5) {
      configuration.icon.font(.system(size: 7)).foregroundStyle(color)
      configuration.title
    }
  }
}

/// A section the inspector has no dedicated view for: title, summary and details.
private struct SectionDisclosure: View {
  let section: EventSection
  @State private var isExpanded = false

  var body: some View {
    if section.details.isEmpty {
      LabeledContent(section.title, value: section.summary)
    } else {
      DisclosureGroup(isExpanded: $isExpanded) {
        DetailSectionsView(sections: section.details, rowID: section.id)
      } label: {
        LabeledContent(section.title, value: section.summary)
      }
    }
  }
}
