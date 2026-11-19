#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  @Suite("Automation editor, clicked", .serialized)
  @MainActor
  struct PagesAutomationEditorTests {
    private let log = ActionLog()

    private func context(editing: Bool = false) -> AutomationEditorContext {
      var context = AutomationEditorContext(
        agents: [
          AutomationOption(id: "a1", name: "Claude Code"),
          AutomationOption(id: "a2", name: "Codex"),
        ], supportsSessionModes: true, describe: { "Summary of \($0.preset.title)" },
        isEditing: editing)
      context.hosts = [AutomationOption(id: "h1", name: "Build Mac")]
      context.sandboxLabel = "New Sandbox"
      context.supportsProjects = true
      context.projects = [AutomationOption(id: "p1", name: "Docs")]
      context.anchoredScheduling = true
      return context
    }

    private func sheet(
      _ draft: EditedValue<AutomationDraftState>, context: AutomationEditorContext
    ) -> OffscreenWindow<AutomationEditorSheet> {
      SystemSideEffects.reset()
      let log = log
      return OffscreenWindow(
        AutomationEditorSheet(
          draft: draft.binding, context: context, save: { log.record("save") },
          cancel: { log.record("cancel") }), width: 720, height: 1_500)
    }

    /// Where the footer's buttons are. A disabled Save isn't a control, but it sits just after Cancel.
    private func footer(
      _ screen: OffscreenWindow<AutomationEditorSheet>
    ) throws -> (cancel: CGPoint, save: CGPoint) {
      let bottom = screen.host.bounds.height - 80
      let cancel = try #require(screen.controlFrames.first { $0.minY > bottom })
      return (
        CGPoint(x: cancel.midX, y: cancel.midY), CGPoint(x: cancel.maxX + 30, y: cancel.midY)
      )
    }

    private func popUp(
      _ screen: OffscreenWindow<AutomationEditorSheet>, showing title: String
    ) throws -> NSButton {
      try #require(screen.popUps.first { $0.title == title }, "no picker showing \(title)")
    }

    @Test("Create stays off until a name, prompt and agent are filled, then saves")
    func fillingIn() throws {
      let draft = EditedValue(AutomationDraftState())
      let screen = sheet(draft, context: context())
      defer { screen.close() }
      #expect(try screen.shows("Create"))
      try screen.click(try footer(screen).save)
      #expect(log.entries.isEmpty, "nothing to save yet")

      let name = try #require(
        screen.textFields.first { $0.placeholderString == "Name your automation" })
      try screen.replaceText(in: name, with: "Brief")
      #expect(draft.value.name == "Brief")
      let prompt = try #require(
        screen.textFields.first { $0.placeholderString?.hasPrefix("What") == true })
      try screen.replaceText(in: prompt, with: "Summarize")
      #expect(draft.value.prompt == "Summarize")
      try screen.click(try footer(screen).save)
      #expect(log.entries.isEmpty, "no agent yet")

      try screen.choose("Codex", inPopUp: try popUp(screen, showing: "Choose an agent"))
      #expect(draft.value.agentID == "a2")
      try screen.click(try footer(screen).save)
      #expect(log.entries == ["save"])
    }

    @Test("Cancel cancels")
    func cancel() throws {
      let draft = EditedValue(AutomationDraftState())
      let screen = sheet(draft, context: context())
      defer { screen.close() }
      try screen.click(try footer(screen).cancel)
      #expect(log.entries == ["cancel"])
    }

    @Test("Return can't save while the form says it can't be saved")
    func returnWhileBlocked() throws {
      let draft = EditedValue(AutomationDraftState(name: "Brief"))
      let screen = sheet(draft, context: context())
      defer { screen.close() }
      // With no field focused, as the keys suite presses it to save a complete form.
      _ = screen.activeWindow.makeFirstResponder(nil)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(log.entries.isEmpty)
    }

    @Test(
      "a blocker, a schedule problem or a save in flight each stop Save",
      arguments: ["blocker", "schedule", "saving"])
    func blockers(kind: String) throws {
      var context = context()
      switch kind {
      case "blocker": context.blocker = "Pick a host before pinning a workspace."
      case "schedule": context.scheduleProblem = "Choose a day."
      default: context.isSaving = true
      }
      let draft = EditedValue(AutomationDraftState(name: "Brief", prompt: "Go", agentID: "a1"))
      let screen = sheet(draft, context: context)
      defer { screen.close() }
      try screen.click(try footer(screen).save)
      #expect(log.entries.isEmpty)
      if kind == "blocker" { #expect(try screen.shows("Pick a host before pinning")) }
      if kind == "schedule" {
        #expect(try screen.shows("Choose a day."))
      }
    }

    @Test("a failed save shows why")
    func saveError() throws {
      var context = context(editing: true)
      context.error = "The server said no"
      let draft = EditedValue(AutomationDraftState(name: "Brief", prompt: "Go", agentID: "a1"))
      let screen = sheet(draft, context: context)
      defer { screen.close() }
      #expect(try screen.shows("The server said no"))
      #expect(try screen.shows("Save changes"))
    }

    @Test("Session continuity waits under Advanced settings, and offers the reset when editing")
    func sessionMode() throws {
      var context = context(editing: true)
      context.hasContinuingSession = true
      let draft = EditedValue(AutomationDraftState(name: "Brief", prompt: "Go", agentID: "a1"))
      let screen = sheet(draft, context: context)
      defer { screen.close() }
      #expect(screen.popUps.allSatisfy { $0.title != "New session each run" }, "folded away")
      try screen.clickElement("automation-advanced")
      #expect(try !screen.shows("Start a new session on the next run"))
      try screen.choose(
        "Continue one session", inPopUp: try popUp(screen, showing: "New session each run"))
      #expect(draft.value.continuesSession)
      #expect(try screen.shows("Start a new session on the next run"))
      try screen.clickElement("automation-start-new-session")
      #expect(draft.value.startNewSession)
    }

    @Test("a server without session modes offers no session picker")
    func noSessionModes() throws {
      var context = context()
      context.supportsSessionModes = false
      let draft = EditedValue(AutomationDraftState())
      let screen = sheet(draft, context: context)
      defer { screen.close() }
      try screen.clickElement("automation-advanced")
      #expect(screen.popUps.allSatisfy { $0.title != "New session each run" })
    }

    @Test("an edit's schedule sits under Advanced settings, by its summary")
    func editedSchedule() throws {
      let draft = EditedValue(AutomationDraftState(schedule: nil, keptRule: "Every 3rd Tuesday"))
      let screen = sheet(draft, context: context(editing: true))
      defer { screen.close() }
      #expect(try !screen.shows("Every 3rd Tuesday"), "folded away")
      try screen.clickElement("automation-advanced")
      #expect(try screen.shows("Every 3rd Tuesday"))
      #expect(screen.popUps.allSatisfy { $0.title != "Every day" }, "no frequency outside its menu")
    }

    @Test("a new automation's schedule button shows the summary as it changes")
    func summaryFollows() throws {
      let draft = EditedValue(AutomationDraftState())
      let screen = sheet(draft, context: context())
      defer { screen.close() }
      #expect(try screen.shows("Summary of Every day"))
      draft.value.schedule?.preset = .hourly
      screen.settle()
      #expect(try screen.shows("Summary of Every hour"))
    }

    @Test("picking a host pins it and enables the folder; picking a sandbox clears both")
    func placement() throws {
      let draft = EditedValue(AutomationDraftState())
      let screen = sheet(draft, context: context())
      defer { screen.close() }
      try screen.clickElement("automation-advanced")
      let folder = try #require(screen.textFields.first { $0.placeholderString == "No workspace" })
      #expect(!folder.isEnabled, "no host to pin a folder on yet")
      try screen.choose("Build Mac", inPopUp: try popUp(screen, showing: "Pick a host"))
      #expect(draft.value.hostID == "h1")
      let pinned = try #require(screen.textFields.first { $0.placeholderString == "No workspace" })
      try screen.replaceText(in: pinned, with: "/work")
      #expect(draft.value.workspace == "/work")

      try screen.choose("New Sandbox", inPopUp: try popUp(screen, showing: "Build Mac"))
      #expect(draft.value.runsInSandbox)
      #expect(draft.value.hostID.isEmpty)
      #expect(draft.value.workspace.isEmpty)
      #expect(try screen.shows("Provisions a fresh sandbox for each run."))
      #expect(screen.textFields.allSatisfy { $0.placeholderString != "No workspace" })

      try screen.choose("Build Mac", inPopUp: try popUp(screen, showing: "New Sandbox"))
      #expect(!draft.value.runsInSandbox)
      #expect(draft.value.hostID == "h1")
    }

    @Test("editing without a pinned host says it follows the most recent one")
    func unpinned() throws {
      let draft = EditedValue(AutomationDraftState())
      let screen = sheet(draft, context: context(editing: true))
      defer { screen.close() }
      #expect(screen.popUps.contains { $0.title == "Most recently active host" })
      #expect(try screen.shows("Runs on the connected host you used most recently."))
    }

    @Test("a continuing sandbox says it keeps one sandbox")
    func continuingSandbox() throws {
      var seed = AutomationDraftState(continuesSession: true)
      seed.runsInSandbox = true
      var context = context()
      context.sandboxLabel = nil
      let screen = sheet(EditedValue(seed), context: context)
      defer { screen.close() }
      #expect(screen.popUps.contains { $0.title == "New Sandbox" }, "still named without a label")
      #expect(try screen.shows("Keeps one sandbox for every run"))
    }

    @Test("values no longer offered still show as themselves, rather than a blank picker")
    func staleValues() throws {
      var seed = AutomationDraftState(name: "Brief", prompt: "Go", agentID: "gone-agent")
      seed.hostID = "gone-host"
      seed.projectID = "gone-project"
      seed.model = "gone-model"
      var context = context(editing: true)
      context.overrides = AutomationOverrideOptions(
        models: [AutomationOption(id: "m1", name: "Opus")], efforts: [], permissionModes: [])
      let screen = sheet(EditedValue(seed), context: context)
      defer { screen.close() }
      try screen.clickElement("automation-advanced")
      let titles = screen.popUps.map(\.title)
      for title in ["gone-agent", "gone-host", "Project unavailable", "gone-model"] {
        #expect(titles.contains(title), "\(titles)")
      }
    }

    @Test("permissions sit beside the agent; project, model and effort under Advanced settings")
    func overrides() throws {
      var context = context()
      let option = { (name: String) in [AutomationOption(id: name.lowercased(), name: name)] }
      context.overrides = AutomationOverrideOptions(
        models: option("Opus"), efforts: option("High"), permissionModes: option("Auto"))
      let draft = EditedValue(AutomationDraftState())
      let screen = sheet(draft, context: context)
      defer { screen.close() }
      try screen.choose("Auto", inPopUp: try popUp(screen, showing: "Default permissions"))
      #expect(draft.value.permissionMode == "auto")
      try screen.clickElement("automation-advanced")
      try screen.choose("Docs", inPopUp: try popUp(screen, showing: "No project"))
      #expect(draft.value.projectID == "p1")
      let defaults = screen.popUps.filter { $0.title == "Default" }
      #expect(defaults.count == 2, "model and effort")
      try screen.choose("Opus", inPopUp: defaults[0])
      try screen.choose("High", inPopUp: defaults[1])
      #expect([draft.value.model, draft.value.effort] == ["opus", "high"])
      try screen.choose("Default", inPopUp: try popUp(screen, showing: "Opus"))
      #expect(draft.value.model.isEmpty)
    }

    @Test("an agent note shows when switching agents")
    func agentNote() throws {
      var context = context(editing: true)
      context.agentNote = "Switching agents starts a new session."
      let screen = sheet(EditedValue(AutomationDraftState(agentID: "a1")), context: context)
      defer { screen.close() }
      #expect(try screen.shows("Switching agents starts a new session."))
    }

  }

  extension PagesAutomationEditorTests {
    @Test("a new automation switches its trigger type through the context, and says when none")
    func triggerType() throws {
      var context = context()
      context.triggerTypes = [AutomationOption(id: "jira", name: "Jira")]
      let log = log
      context.switchTriggerType = { log.record("type \($0 ?? "schedule")") }
      let screen = sheet(EditedValue(AutomationDraftState()), context: context)
      defer { screen.close() }
      try screen.choose("Jira", inPopUp: try popUp(screen, showing: "Schedule"))
      #expect(log.entries == ["type jira"])
      #expect(try !screen.shows("Integration triggers aren\u{2019}t available on this server."))

      let bare = sheet(EditedValue(AutomationDraftState()), context: self.context())
      defer { bare.close() }
      #expect(try bare.shows("Integration triggers aren\u{2019}t available on this server."))
      let edited = sheet(EditedValue(AutomationDraftState()), context: self.context(editing: true))
      defer { edited.close() }
      #expect(edited.popUps.allSatisfy { $0.title != "Schedule" }, "an edit keeps its type")
    }
  }

  extension PagesAutomationEditorTests {
    @Test("the cost limit, MCP services and a session copy write back, with what blocks Save")
    func costServicesAndSource() throws {
      var context = context()
      context.mcpServices = [
        AutomationMcpOption(id: "github", title: "GitHub", isConnected: true),
        AutomationMcpOption(id: "jira", title: "Jira", isConnected: false),
      ]
      context.costLimitProblem = "Enter a cost limit greater than zero, or leave it blank."
      context.mcpProblem = "Sign in to each selected MCP service, or turn it off."
      var seed = AutomationDraftState(name: "Copy", agentID: "a1")
      seed.sourceSessionID = "s1"
      seed.sourceSessionTitle = "Release notes"
      let draft = EditedValue(seed)
      let screen = sheet(draft, context: context)
      defer { screen.close() }
      #expect(try screen.shows("Starts from"))
      #expect(try screen.shows("Release notes"))
      #expect(try screen.shows("Enter a cost limit greater than zero, or leave it blank."))
      #expect(try screen.shows("Sign in to each selected MCP service, or turn it off."))
      #expect(try screen.shows("No MCPs"), "the problems opened Advanced settings")
      let cost = try #require(screen.textFields.first { $0.placeholderString == "No limit" })
      try screen.replaceText(in: cost, with: "2.5")
      #expect(draft.value.maxCost == "2.5")
      let services = try screen.titles(inPopUp: try popUp(screen, showing: "No MCPs"))
      #expect(services.contains("GitHub"))
      try screen.choose("GitHub", inPopUp: try popUp(screen, showing: "No MCPs"))
      #expect(draft.value.mcpServices == ["github"])
      #expect(
        screen.popUps.allSatisfy { $0.title != "New session each run" },
        "a session copy starts each run anew")
    }

    @Test("the form keeps the web's order: name, type and schedule, prompt, run on, Advanced")
    func layout() throws {
      var context = context()
      context.triggerTypes = [AutomationOption(id: "jira", name: "Jira")]
      context.switchTriggerType = { _ in }
      context.overrides = AutomationOverrideOptions(
        models: [], efforts: [], permissionModes: [AutomationOption(id: "auto", name: "Auto")])
      let screen = sheet(
        EditedValue(AutomationDraftState(name: "Brief", agentID: "a1")), context: context)
      defer { screen.close() }
      let order = [
        "automation-name", "automation-trigger-type", "automation-schedule-preset",
        "automation-prompt", "automation-host", "automation-agent", "automation-permission-mode",
        "automation-advanced",
      ]
      let frames = try screen.withAccessibilityTree {
        try (order + ["automation-save"]).map { try screen.accessibilityFrame($0) }
      }
      for (above, below) in zip(frames.dropLast(), frames.dropFirst().dropLast()) {
        #expect(above.maxY <= below.minY + 1, "\(above) is above \(below)")
      }
      let save = try #require(frames.last)
      #expect(save.maxX > screen.host.bounds.width - 40, "Create sits at the bottom right")
      #expect(save.minY > try #require(frames.dropLast().last).maxY)
    }

    @Test("the frequency is a pop-up menu, and a kept rule offers a new schedule")
    func scheduleMenu() throws {
      let draft = EditedValue(AutomationDraftState())
      let screen = sheet(draft, context: context())
      defer { screen.close() }
      try screen.choose("Every hour", inPopUp: try popUp(screen, showing: "Every day"))
      #expect(draft.value.schedule?.preset == .hourly)
      let kept = EditedValue(AutomationDraftState(schedule: nil, keptRule: "Every 3rd Tuesday"))
      let edited = sheet(kept, context: context(editing: true))
      defer { edited.close() }
      try edited.clickElement("automation-advanced")
      #expect(try edited.shows("Choose a frequency to replace it."))
      try edited.clickElement("automation-schedule-replace")
      #expect(kept.value.schedule == ScheduleChoice())
    }
  }
#endif
