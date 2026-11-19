import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents
@testable import OmnigentWorkspaceUI

extension LookFixtures {
  // MARK: Inbox

  static var suggestion: InboxItem {
    var item = InboxItem(
      id: "s1", kind: .suggestion, sessionId: "session-s1", sessionTitle: "Certificate check",
      preview: "It expires on Friday.", date: now.addingTimeInterval(-600))
    item.agentName = "Ops agent"
    item.suggestion = InboxSuggestion(
      kindLabel: "Reminder", title: "Renew the certificate",
      body: "The staging certificate expires on **Friday**. Renewing takes about five minutes.",
      charts: [
        InboxChart(
          isBar: false, title: "Days left", labels: ["Mon", "Tue", "Wed", "Thu", "Fri"],
          series: [.init(name: "Days", values: [5, 4, 3, 2, 1])], markers: [4: "Expires"])
      ],
      links: [InboxLink(title: "Open the run", sessionID: "abc")],
      actions: ["Renew it", "Later"], sourceTitle: "Cert rotation",
      dismissChoices: [
        InboxDismissChoice(id: "not_now", title: "Not now"),
        InboxDismissChoice(id: "wrong", title: "Not useful"),
      ])
    return item
  }

  static var failure: InboxItem {
    var item = InboxItem(
      id: "f1", kind: .automationFailure, sessionId: "", sessionTitle: "Nightly sync",
      preview: "Host \u{00B7} The host was offline.", date: now.addingTimeInterval(-3_600))
    item.automationFailure = InboxAutomationFailure(
      automationID: "t1", name: "Nightly sync", reason: "Host \u{00B7} The host was offline.")
    return item
  }

  static func inbox(_ items: [InboxItem]) -> some View {
    var actions = InboxActions(open: { _ in }, markRead: { _ in })
    actions.takeSuggestionAction = { _, _ in }
    actions.dismissSuggestion = { _, _ in }
    actions.openLink = { _ in }
    actions.openSource = { _ in }
    actions.openAutomation = { _ in }
    var state = InboxViewState(items: items, now: now)
    state.unreadSuggestionCount = 1
    return InboxView(state: state, actions: actions)
  }

  // MARK: Settings

  static func settings(@ViewBuilder _ content: () -> some View) -> some View {
    Form { content() }
      .formStyle(.grouped)
  }

  @ViewBuilder static var agents: some View {
    CustomAgentsSettingsSection(
      state: CustomAgentsSettingsState(
        serverAgents: [
          CustomAgentRow(
            id: "a1", name: "Reviewer", description: "Reviews pull requests.", harness: "Codex",
            created: nil, edited: nil)
        ],
        myAgents: [
          CustomAgentRow(
            id: "a2", name: "Release helper", description: "Drafts release notes.",
            harness: "Claude Code", created: now.addingTimeInterval(-86_400 * 20),
            edited: now.addingTimeInterval(-86_400 * 2)),
          CustomAgentRow(
            id: "a3", name: "Docs writer", description: nil, harness: "Codex",
            created: now.addingTimeInterval(-86_400 * 9), edited: nil),
        ]),
      actions: CustomAgentsSettingsActions(
        create: {}, edit: { _ in }, save: { _ in }, remove: { _, _ in }, closeEditor: {}))
  }

  @ViewBuilder static var sessions: some View {
    SessionTitleInstructionsPane(
      state: .ready(saved: "Start every title with the ticket id.", maxChars: 500),
      actions: ServerSettingsActions())
  }

  private static var catalog: HarnessCatalogState {
    var catalog = HarnessCatalogState()
    catalog.servers = [
      .init(id: "docs", title: "docs", detail: "stdio \u{00B7} npx docs-server"),
      .init(id: "tracker", title: "tracker", detail: "https://mcp.example.com", isOff: true),
    ]
    catalog.skills = [
      .init(name: "review", title: "review", description: "Reviews a diff.", opens: true)
    ]
    catalog.plugins = [plugin]
    return catalog
  }

  private static var plugin: HarnessCatalogState.Plugin {
    .init(
      id: "p1", name: "release-tools", detail: "1.2.0 \u{00B7} example-marketplace",
      description: "Helpers for cutting releases.",
      skills: [
        .init(name: "notes", title: "notes", description: "Drafts release notes.", opens: true)
      ],
      servers: [.init(id: "changelog", title: "changelog", detail: "stdio")])
  }

  private static var harnessState: HarnessDetailState {
    var state = HarnessDetailState(
      harness: "claude", name: "Claude Code", hostName: "Build host", status: "Ready",
      isReady: true, credentialLabel: "Signed in", credentialDescription: "Account credential")
    state.catalog = catalog
    return state
  }

  @ViewBuilder static var harness: some View {
    HarnessDetailView(
      state: harnessState,
      actions: HarnessDetailActions(back: {}, fixWarning: {}, fixCredential: {}))
  }

  @ViewBuilder static var pluginPage: some View {
    HarnessPluginPage(plugin: plugin, back: {}, openSkill: { _ in })
  }

  // MARK: Tasks

  static var tasks: some View {
    let started = now.addingTimeInterval(-300)
    let list = TaskListState(
      planName: "Ship the JSON flag", updatedAt: started, summary: "1 of 4 finished",
      counts: [
        TaskCountLine(state: .running, text: "1 running"),
        TaskCountLine(state: .failed, text: "1 failed"),
      ],
      canStop: true, fromPlan: true,
      rows: [
        TaskRowState(
          id: "build", number: 1, name: "Build", state: .done, stateLabel: "Done",
          detail: .text("Compiled"), endedAt: started),
        TaskRowState(
          id: "test", number: 2, name: "Run the tests", state: .running, stateLabel: "Running",
          detail: .text("Running the suite"), runningSince: started,
          action: TaskMenuItem(kind: .stop, title: "Stop")),
        TaskRowState(
          id: "docs", number: 3, name: "Update the docs", state: .failed, stateLabel: "Failed",
          detail: .text("Lint broke"), action: TaskMenuItem(kind: .retry, title: "Retry")),
        TaskRowState(
          id: "ship", number: 4, name: "Ship it", state: .waiting, stateLabel: "Not started",
          detail: .cantStart(failed: "Update the docs"),
          dependsOn: ["Run the tests", "Update the docs"]),
      ])
    return TasksPanel(
      content: TasksPanelContent(
        state: .loaded(list), taskToShow: nil, perform: { _, _ in }, stop: {},
        continuePlan: {}, showInChat: { _ in }, retry: {}, shown: {}))
  }

  // MARK: Viewers

  /// A two-page PDF with a heading and lines of text on each page.
  static var pdf: Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
      let context = unsafe CGContext(consumer: consumer, mediaBox: &box, nil)
    else { return Data() }
    for page in 1...2 {
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(gray: 0.15, alpha: 1))
      context.fill(CGRect(x: 72, y: 690, width: 300, height: 24))
      context.setFillColor(CGColor(gray: 0.55, alpha: 1))
      for line in 0..<(page == 1 ? 18 : 10) {
        let width = CGFloat(468 - (line % 3) * 60)
        context.fill(CGRect(x: 72, y: 640 - CGFloat(line) * 26, width: width, height: 10))
      }
      context.endPDFPage()
    }
    context.closePDF()
    return data as Data
  }

  static var video: some View {
    WorkspaceVideoView(
      path: "recordings/sign-in.mp4", source: LookChapteredSource(), download: { _ in },
      openFile: {}
    )
    .padding(Theme.Spacing.medium)
  }
}
