#if os(macOS)
  import Foundation
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// Each Automations screen at a Mac, iPad and iPhone width, written as PNGs where
  /// `OMNIGENT_UI_RENDER_DIR` names a directory, to compare with the web's layout.
  @Suite("Automations screens drawn at each device width", .serialized)
  @MainActor
  struct AutomationUXRenderTests {
    enum Device: String, CaseIterable, CustomTestStringConvertible {
      case mac, ipad, iphone

      var testDescription: String { rawValue }

      /// A page's width; the editor is a sheet, as wide as the web's dialog on a Mac.
      func width(sheet: Bool) -> CGFloat {
        switch self {
        case .mac: sheet ? 720 : 960
        case .ipad: sheet ? 700 : 820
        case .iphone: 390
        }
      }

      var height: CGFloat {
        switch self {
        case .mac: 900
        case .ipad: 1_180
        case .iphone: 844
        }
      }

      var layout: LayoutWidth { self == .iphone ? .compact : .regular }
    }

    enum Screen: String, CaseIterable, CustomTestStringConvertible {
      case list, empty, templates, editorSchedule, editorTrigger, editorEdit, detail

      var testDescription: String { rawValue }
      var isSheet: Bool { [.editorSchedule, .editorTrigger, .editorEdit].contains(self) }
    }

    @Test("draws the screen", arguments: Screen.allCases, Device.allCases)
    func render(screen: Screen, device: Device) throws {
      let rendered = try RenderSupport.render(
        view(screen), width: device.width(sheet: screen.isSheet), height: device.height,
        scheme: .light, layout: device.layout)
      #expect(RenderSupport.inkCoverage(rendered) > 0.005, "\(screen) is blank on \(device)")
      try RenderSupport.write(rendered, name: "automations-\(screen.rawValue)-\(device.rawValue)")
    }

    private func view(_ screen: Screen) -> AnyView {
      switch screen {
      case .list:
        AnyView(AutomationsView(state: Self.list, actions: Self.listActions))
      case .empty:
        AnyView(AutomationsView(state: Self.empty, actions: Self.listActions))
      case .templates:
        AnyView(
          AutomationsView(state: Self.list, actions: Self.listActions, initialTab: .templates))
      case .editorSchedule:
        AnyView(
          AutomationEditorSheet(
            draft: .constant(Self.scheduleDraft), context: Self.editorContext(), save: {},
            cancel: {}))
      case .editorTrigger:
        AnyView(
          AutomationEditorSheet(
            draft: .constant(Self.triggerDraft), context: Self.triggerContext, save: {},
            cancel: {}))
      case .editorEdit:
        AnyView(
          AutomationEditorSheet(
            draft: .constant(Self.editedDraft), context: Self.editorContext(editing: true),
            save: {}, cancel: {}))
      case .detail:
        AnyView(AutomationDetailView(state: Self.detail, actions: Self.detailActions))
      }
    }
  }

  extension AutomationUXRenderTests {
    static var listActions: AutomationsActions {
      var actions = AutomationsActions()
      actions.filter = { _, _ in }
      actions.create = {}
      actions.createTrigger = { _ in }
      actions.openDetail = { _ in }
      actions.edit = { _ in }
      actions.setPaused = { _, _ in }
      actions.runNow = { _ in }
      actions.delete = { _ in }
      actions.share = { _ in }
      actions.openSession = { _ in }
      actions.retry = {}
      actions.dismissError = {}
      actions.showIntro = {}
      return actions
    }

    static var templates: [AutomationTemplateCard] {
      [
        AutomationTemplateCard(
          id: "jira", title: "Jira tickets",
          description: "Start a session for each new or updated ticket that matches.",
          requirement: "Requires a Jira MCP server.", systemImage: "ticket"),
        AutomationTemplateCard(
          id: "slack", title: "Slack messages",
          description: "Start a session for each new message in the channels you pick.",
          requirement: "Requires a Slack MCP server.", systemImage: "number"),
        AutomationTemplateCard(
          id: "github", title: "GitHub pull requests",
          description: "Start a session for each pull request or issue that matches.",
          requirement: "Requires the GitHub CLI or a GitHub MCP server.",
          systemImage: "smallcircle.filled.circle"),
        AutomationTemplateCard(
          id: "linear", title: "Linear issues",
          description: "Start a session for each new issue in the teams you pick.",
          requirement: "Requires a Linear MCP server.",
          systemImage: "line.3.horizontal.decrease.circle"),
        AutomationTemplateCard(
          id: "pagerduty", title: "PagerDuty incidents",
          description: "Start a session for each new incident on the services you pick.",
          requirement: "Requires a PagerDuty MCP server.", systemImage: "bell.badge"),
      ]
    }

    static var list: AutomationsViewState {
      var standup = AutomationRow(
        id: "a1", name: "Daily standup notes", scheduleText: "Every weekday at 9:00 AM",
        nextRunText: "in 3 hours")
      standup.canShare = true
      var failed = AutomationRow(
        id: "a2", name: "Nightly test sweep", scheduleText: "Every day at 2:00 AM",
        nextRunText: "in 14 hours")
      failed.lastRunFailed = true
      var trigger = AutomationRow(
        id: "a3", name: "Triage new tickets", scheduleText: "Every 10 minutes")
      trigger.isTrigger = true
      let paused = AutomationRow(
        id: "a4", name: "Weekly dependency review",
        scheduleText: "Every week on Monday at 10:00 AM",
        isPaused: true)
      var state = AutomationsViewState(rows: [standup, failed, trigger, paused], hasAny: true)
      state.templates = templates
      state.shared = SharedAutomationsState()
      return state
    }

    static var empty: AutomationsViewState {
      var state = AutomationsViewState(rows: [], hasAny: false)
      state.templates = templates
      return state
    }

    static func editorContext(editing: Bool = false) -> AutomationEditorContext {
      var context = AutomationEditorContext(
        agents: [
          AutomationOption(id: "a1", name: "Claude Code"),
          AutomationOption(id: "a2", name: "Codex"),
        ], supportsSessionModes: true, describe: { _ in "Every day at 9:00 AM" },
        isEditing: editing)
      context.hosts = [
        AutomationOption(id: "h1", name: "Build Mac"),
        AutomationOption(id: "h2", name: "Lab Mac (offline)"),
      ]
      context.sandboxLabel = "New Sandbox"
      context.supportsProjects = true
      context.projects = [AutomationOption(id: "p1", name: "Automations")]
      context.anchoredScheduling = true
      context.offersMinutes = true
      context.minuteRange = 10...21_960
      context.overrides = AutomationOverrideOptions(
        models: [
          AutomationOption(id: "opus", name: "Opus"),
          AutomationOption(id: "sonnet", name: "Sonnet"),
        ],
        efforts: [
          AutomationOption(id: "medium", name: "Medium"),
          AutomationOption(id: "high", name: "High"),
        ],
        permissionModes: [
          AutomationOption(id: "auto", name: "Auto"),
          AutomationOption(id: "acceptEdits", name: "Accept edits"),
        ])
      context.mcpServices = [
        AutomationMcpOption(id: "github", title: "GitHub", isConnected: true),
        AutomationMcpOption(id: "jira", title: "Jira", isConnected: false),
      ]
      context.triggerTypes = templates.map { AutomationOption(id: $0.id, name: $0.title) }
      return context
    }

    static var scheduleDraft: AutomationDraftState {
      var draft = AutomationDraftState(agentID: "a1")
      draft.hostID = "h1"
      draft.permissionMode = "auto"
      draft.projectID = "p1"
      return draft
    }

    static var editedDraft: AutomationDraftState {
      var draft = AutomationDraftState(
        name: "Daily standup notes",
        prompt:
          "Read yesterday's merged pull requests and open issues, then write a short summary of what changed and what needs attention today.",
        agentID: "a1", schedule: ScheduleChoice(preset: .weekdays), continuesSession: false)
      draft.hostID = "h1"
      draft.workspace = "/Users/builder/projects/app"
      draft.model = "opus"
      draft.maxCost = "5"
      return draft
    }

    static var triggerTemplate: AutomationTriggerTemplate {
      var template = AutomationTriggerTemplate(
        events: [
          AutomationOption(id: "created", name: "Ticket created"),
          AutomationOption(id: "updated", name: "Ticket updated"),
        ], scopeLabel: "project", scopePlaceholder: "ENG, OPS",
        fields: [
          AutomationTriggerTemplate.Field(
            id: "assignee", title: "Assignee",
            operations: [
              .init(id: "is", title: "is", isValueless: false),
              .init(id: "empty", title: "is unassigned", isValueless: true),
            ], placeholder: "name"),
          AutomationTriggerTemplate.Field(
            id: "label", title: "Label",
            operations: [.init(id: "is", title: "is", isValueless: false)],
            placeholder: "needs-triage"),
        ],
        instructionsPlaceholder:
          "For example: Reproduce the bug, find the cause, and open a pull request with a fix.",
        linkBackLabel: "Comment on the ticket with a link to its session",
        maxInstructions: 2_000)
      template.eventDetails = [
        "created": .init(
          description:
            "Starts a session for each new ticket in the projects you list. Each check looks back over the time since the last one.",
          scopeLabel: "project", scopePlaceholder: "ENG, OPS",
          authorAction: "create a ticket in these projects"),
        "updated": .init(
          description: "Starts a session for each ticket updated in the projects you list.",
          scopeLabel: "project", scopePlaceholder: "ENG, OPS",
          authorAction: "update a ticket in these projects"),
      ]
      template.scopeOperators = [
        AutomationOption(id: "is", name: "is"), AutomationOption(id: "in", name: "in"),
      ]
      template.serviceName = "Jira"
      template.toolsExample = "a Jira MCP server"
      template.systemImage = "ticket"
      return template
    }

    static var triggerDraft: AutomationDraftState {
      var draft = AutomationDraftState(name: "Jira tickets", agentID: "a1", continuesSession: true)
      draft.hostID = "h1"
      draft.isTrigger = true
      var trigger = AutomationTriggerDraft(source: "jira", event: "created")
      trigger.scope = "ENG"
      var label = AutomationTriggerCondition(field: "label", operation: "is")
      label.value = "needs-triage"
      trigger.conditions = [label]
      draft.trigger = trigger
      return draft
    }

    static var triggerContext: AutomationEditorContext {
      var context = editorContext()
      context.trigger = triggerTemplate
      context.triggerPrompt = "Every check, list the new tickets in ENG labeled needs-triage."
      return context
    }

    static var detailActions: AutomationDetailActions {
      var actions = AutomationDetailActions()
      actions.back = {}
      actions.edit = {}
      actions.delete = {}
      actions.runNow = {}
      actions.setPaused = { _ in }
      actions.share = {}
      actions.openSession = { _ in }
      actions.openPullRequest = { _ in }
      actions.retry = {}
      return actions
    }

    static var detail: AutomationDetailState {
      var state = AutomationDetailState(
        id: "a1", name: "Daily standup notes", isPaused: false,
        scheduleText: "Every weekday at 9:00 AM \u{00B7} Next run in 3 hours",
        prompt:
          "Read yesterday's merged pull requests and open issues, then write a short summary of what changed and what needs attention today.",
        agent: "Claude Code", host: "Build Mac")
      state.canShare = true
      state.configuration = [
        AutomationConfigField(label: "Agent", value: "Claude Code"),
        AutomationConfigField(label: "Host", value: "Build Mac"),
        AutomationConfigField(label: "Model", value: "Opus"),
        AutomationConfigField(label: "Effort", value: "Agent default"),
        AutomationConfigField(label: "Permission mode", value: "Auto"),
        AutomationConfigField(label: "Session", value: "New session each run"),
        AutomationConfigField(label: "Workspace", value: "/Users/builder/projects/app"),
        AutomationConfigField(label: "Timezone", value: "America/Los_Angeles"),
        AutomationConfigField(label: "Cost limit per run", value: "$5.00"),
      ]
      var running = AutomationRunRow(id: "r1", indicator: .inFlight, timestamp: "Today, 9:00 AM")
      running.statusLabel = "Running"
      running.sessionID = "s1"
      var merged = AutomationRunRow(id: "r2", indicator: .unread, timestamp: "Yesterday, 9:00 AM")
      merged.duration = "4m 12s"
      merged.sessionCost = "Session cost $0.84"
      merged.sessionID = "s2"
      if let url = URL(string: "https://example.com/acme/app/pull/212") {
        merged.pullRequestSummary = "PR #212 merged"
        merged.pullRequests = [
          AutomationRunPullRequest(
            url: url, number: "#212", title: "Summarize standup notes", status: "Merged",
            repository: "acme/app", origin: "Opened by this run")
        ]
      }
      var failed = AutomationRunRow(id: "r3", indicator: .failed, timestamp: "Nov 14, 9:00 AM")
      failed.duration = "12s"
      failed.failureStage = "Host"
      failed.failureReason = "The host was offline."
      var done = AutomationRunRow(id: "r4", indicator: .completed, timestamp: "Nov 13, 9:00 AM")
      done.duration = "3m 58s"
      done.sessionCost = "Session cost $0.71"
      done.sessionID = "s4"
      let skipped = AutomationRunRow(id: "r5", indicator: .skipped, timestamp: "Nov 12, 9:00 AM")
      state.runs = [running, merged, failed, done, skipped]
      return state
    }
  }
#endif
