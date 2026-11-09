#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

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
          cancel: { log.record("cancel") }), width: 700, height: 1_500)
    }

    /// Where the footer's buttons are. A disabled Save isn't a control, but it sits just after Cancel.
    private func footer(
      _ screen: OffscreenWindow<AutomationEditorSheet>
    ) throws -> (cancel: CGPoint, save: CGPoint) {
      let bottom = screen.host.bounds.height - 80
      let cancel = try #require(screen.controlFrames.first { $0.minY > bottom })
      return (
        CGPoint(x: cancel.midX, y: cancel.midY), CGPoint(x: cancel.maxX + 40, y: cancel.midY)
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
      #expect(try screen.shows("Create automation"))
      try screen.click(try footer(screen).save)
      #expect(log.entries.isEmpty, "nothing to save yet")

      let name = try #require(screen.textFields.first { $0.placeholderString == "daily-brief" })
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
      let name = try #require(screen.textFields.first { $0.placeholderString == "daily-brief" })
      try screen.click(name)
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
      if kind == "schedule" { #expect(try screen.shows("Choose a day.")) }
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

    @Test("choosing a session mode explains it, and offers the reset when editing")
    func sessionMode() throws {
      var context = context(editing: true)
      context.hasContinuingSession = true
      let draft = EditedValue(AutomationDraftState(name: "Brief", prompt: "Go", agentID: "a1"))
      let screen = sheet(draft, context: context)
      defer { screen.close() }
      #expect(try screen.shows("Each run starts a new session."))
      #expect(screen.switches.isEmpty)
      try screen.choose(
        "Continue in the same session", inPopUp: try popUp(screen, showing: "New session each run"))
      #expect(draft.value.continuesSession)
      #expect(try screen.shows("The first run starts a session"))
      let reset = try #require(screen.switches.first)
      try screen.click(reset)
      #expect(draft.value.startNewSession)
    }

    @Test("a server without session modes offers no session picker")
    func noSessionModes() throws {
      var context = context()
      context.supportsSessionModes = false
      let draft = EditedValue(AutomationDraftState())
      let screen = sheet(draft, context: context)
      defer { screen.close() }
      #expect(screen.popUps.allSatisfy { $0.title != "New session each run" })
    }

    @Test("a rule the form can't edit stays until a new schedule is chosen")
    func keptRule() throws {
      let draft = EditedValue(AutomationDraftState(schedule: nil, keptRule: "Every 3rd Tuesday"))
      let screen = sheet(draft, context: context(editing: true))
      defer { screen.close() }
      #expect(try screen.shows("Every 3rd Tuesday"))
      #expect(try screen.shows("Choose a frequency to replace it."))
      #expect(screen.popUps.allSatisfy { $0.title != "Every day" })
      // Choose a new schedule, then Cancel; Save is disabled.
      try screen.clickButton(at: 0)
      #expect(draft.value.schedule == ScheduleChoice())
      #expect(try screen.shows("Summary of Every day"))
    }

    @Test("the summary follows the schedule")
    func summaryFollows() throws {
      let draft = EditedValue(AutomationDraftState())
      let screen = sheet(draft, context: context())
      defer { screen.close() }
      #expect(try screen.shows("Summary of Every day"))
      try screen.choose("Every hour", inPopUp: try popUp(screen, showing: "Every day"))
      #expect(try screen.shows("Summary of Every hour"))
    }

    @Test("picking a host offers a folder; picking a sandbox clears both")
    func placement() throws {
      let draft = EditedValue(AutomationDraftState())
      let screen = sheet(draft, context: context())
      defer { screen.close() }
      #expect(try screen.shows("Pick the host this automation runs on."))
      #expect(screen.textFields.allSatisfy { $0.placeholderString != "Home folder" })
      try screen.choose("Build Mac", inPopUp: try popUp(screen, showing: "Pick a host"))
      #expect(draft.value.hostID == "h1")
      #expect(try screen.shows("A run fails while the host is offline."))
      let folder = try #require(screen.textFields.first { $0.placeholderString == "Home folder" })
      try screen.replaceText(in: folder, with: "/work")
      #expect(draft.value.workspace == "/work")

      try screen.choose("New Sandbox", inPopUp: try popUp(screen, showing: "Build Mac"))
      #expect(draft.value.runsInSandbox)
      #expect(draft.value.hostID.isEmpty)
      #expect(draft.value.workspace.isEmpty)
      #expect(try screen.shows("Provisions a fresh sandbox for each run."))

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
      let titles = screen.popUps.map(\.title)
      for title in ["gone-agent", "gone-host", "Project unavailable", "gone-model"] {
        #expect(titles.contains(title), "\(titles)")
      }
    }

    @Test("project, model, effort and permission mode write back, and Default clears")
    func overrides() throws {
      var context = context()
      let option = { (name: String) in [AutomationOption(id: name.lowercased(), name: name)] }
      context.overrides = AutomationOverrideOptions(
        models: option("Opus"), efforts: option("High"), permissionModes: option("Auto"))
      let draft = EditedValue(AutomationDraftState())
      let screen = sheet(draft, context: context)
      defer { screen.close() }
      #expect(try screen.shows("will wait for approval that never comes"))
      #expect(try !screen.shows("default model, effort, and permission settings"))
      try screen.choose("Docs", inPopUp: try popUp(screen, showing: "No project"))
      #expect(draft.value.projectID == "p1")
      let defaults = screen.popUps.filter { $0.title == "Default" }
      #expect(defaults.count == 3)
      try screen.choose("Opus", inPopUp: defaults[0])
      try screen.choose("High", inPopUp: defaults[1])
      try screen.choose("Auto", inPopUp: defaults[2])
      #expect(
        [draft.value.model, draft.value.effort, draft.value.permissionMode] == [
          "opus", "high", "auto",
        ])
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
      #expect(try screen.shows("default model, effort, and permission settings"))
    }
  }
#endif
