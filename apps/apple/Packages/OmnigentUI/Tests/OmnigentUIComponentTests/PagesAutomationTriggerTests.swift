#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Automation trigger fields, clicked", .serialized)
  @MainActor
  struct PagesAutomationTriggerTests {
    private let log = ActionLog()

    private var template: AutomationTriggerTemplate {
      typealias Operation = AutomationTriggerTemplate.Operation
      return AutomationTriggerTemplate(
        events: [
          AutomationOption(id: "created", name: "A ticket is created"),
          AutomationOption(id: "updated", name: "A ticket is updated"),
        ], scopeLabel: "in project", scopePlaceholder: "ENG",
        fields: [
          AutomationTriggerTemplate.Field(
            id: "assignee", title: "Assignee",
            operations: [
              Operation(id: "unassigned", title: "is unassigned", isValueless: true),
              Operation(id: "is", title: "is", isValueless: false),
            ], placeholder: "name"),
          AutomationTriggerTemplate.Field(
            id: "label", title: "Label",
            operations: [Operation(id: "has", title: "has", isValueless: false)],
            placeholder: "bug"),
        ], instructionsPlaceholder: "What each session does", linkBackLabel: "Post a link back",
        maxInstructions: 10)
    }

    private func draft(
      conditions: [AutomationTriggerCondition] = [], instructions: String = ""
    ) -> EditedValue<AutomationDraftState> {
      var trigger = AutomationTriggerDraft(source: "jira", event: "created")
      trigger.conditions = conditions
      trigger.instructions = instructions
      var draft = AutomationDraftState(name: "Triage", agentID: "a1")
      draft.trigger = trigger
      return EditedValue(draft)
    }

    private func sheet(
      _ draft: EditedValue<AutomationDraftState>, prompt: String = "",
      template: AutomationTriggerTemplate? = nil
    ) -> OffscreenWindow<AutomationEditorSheet> {
      SystemSideEffects.reset()
      var context = AutomationEditorContext(
        agents: [AutomationOption(id: "a1", name: "Claude Code")], supportsSessionModes: true,
        describe: { _ in "" })
      context.trigger = template ?? self.template
      context.triggerPrompt = prompt
      let log = log
      return OffscreenWindow(
        AutomationEditorSheet(
          draft: draft.binding, context: context, save: { log.record("save") }, cancel: {}),
        width: 900, height: 1_500)
    }

    @Test("the event and scope write back; the session stays a single kept session")
    func eventAndScope() throws {
      let draft = draft()
      let screen = sheet(draft)
      defer { screen.close() }
      let event = try #require(screen.popUps.first { $0.title == "A ticket is created" })
      try screen.choose("A ticket is updated", inPopUp: event)
      #expect(draft.value.trigger?.event == "updated")
      let scope = try #require(screen.textFields.first { $0.placeholderString == "ENG" })
      try screen.replaceText(in: scope, with: "OPS")
      #expect(draft.value.trigger?.scope == "OPS")
      #expect(try screen.shows("Trigger automations keep one session"))
      let session = try #require(screen.popUps.first { $0.title == "New session each run" })
      #expect(!session.isEnabled)
    }

    @Test("a trigger can't be saved until its prompt renders")
    func saveNeedsPrompt() throws {
      let draft = draft()
      let blocked = sheet(draft)
      defer { blocked.close() }
      // A disabled Save isn't a control: it sits just after Cancel, the last one.
      let cancel = try #require(blocked.controlFrames.last)
      try blocked.click(CGPoint(x: cancel.maxX + 40, y: cancel.midY))
      #expect(log.entries.isEmpty)

      let ready = sheet(draft, prompt: "Rendered prompt")
      defer { ready.close() }
      let save = try #require(ready.controlFrames.last)
      try ready.click(CGPoint(x: save.midX, y: save.midY))
      #expect(log.entries == ["save"])
    }

    @Test("Add condition starts on the first field's default comparison, with no value to fill")
    func addCondition() throws {
      let draft = draft()
      let screen = sheet(draft)
      defer { screen.close() }
      #expect(screen.textFields.allSatisfy { $0.placeholderString != "name" })
      // Add condition, then Cancel; Save is disabled.
      try screen.clickButton(at: 0)
      let added = try #require(draft.value.trigger?.conditions.first)
      #expect(added.field == "assignee")
      #expect(added.operation == "unassigned")
      #expect(
        screen.textFields.allSatisfy { $0.placeholderString != "name" },
        "is unassigned has no value")
    }

    @Test("a comparison with a value asks for one, and switching field resets the comparison")
    func conditionEditing() throws {
      let condition = AutomationTriggerCondition(field: "assignee", operation: "unassigned")
      let draft = draft(conditions: [condition])
      let screen = sheet(draft)
      defer { screen.close() }
      let comparison = try #require(screen.popUps.first { $0.title == "is unassigned" })
      try screen.choose("is", inPopUp: comparison)
      #expect(draft.value.trigger?.conditions.first?.operation == "is")
      let value = try #require(screen.textFields.first { $0.placeholderString == "name" })
      try screen.replaceText(in: value, with: "ahir")
      #expect(draft.value.trigger?.conditions.first?.value == "ahir")

      let field = try #require(screen.popUps.first { $0.title == "Assignee" })
      try screen.choose("Label", inPopUp: field)
      #expect(draft.value.trigger?.conditions.first?.field == "label")
      #expect(draft.value.trigger?.conditions.first?.operation == "has")
    }

    @Test("Remove takes out that condition and keeps the others")
    func removeCondition() throws {
      let first = AutomationTriggerCondition(field: "assignee", operation: "is")
      let second = AutomationTriggerCondition(field: "label", operation: "has")
      let draft = draft(conditions: [first, second])
      let screen = sheet(draft)
      defer { screen.close() }
      // Each row's Remove comes first, then Add condition and Cancel.
      #expect(screen.buttonFrames.count == 4)
      try screen.clickButton(at: 0)
      #expect(draft.value.trigger?.conditions.map(\.id) == [second.id])
    }

    @Test("too-long instructions say so; the link-back toggle writes back")
    func instructions() throws {
      let draft = draft()
      let screen = sheet(draft)
      defer { screen.close() }
      let field = try #require(
        screen.textFields.first { $0.placeholderString == "What each session does" })
      try screen.replaceText(in: field, with: "0123456789")
      #expect(try !screen.shows("Keep the instructions under"))
      try screen.type("x")
      #expect(draft.value.trigger?.instructions == "0123456789x")
      #expect(try screen.shows("Keep the instructions under 10 characters."))
      #expect(draft.value.trigger?.linkBack == true)
      try screen.click(try #require(screen.switches.last))
      #expect(draft.value.trigger?.linkBack == false)
    }

    @Test("Edit as a prompt takes over the rendered text and leaves the trigger")
    func editAsPrompt() throws {
      let draft = draft()
      let screen = sheet(draft, prompt: "Rendered prompt")
      defer { screen.close() }
      // Add condition, the disclosure, Edit as a prompt, Cancel, Save.
      let frames = screen.buttonFrames
      let edit = frames[frames.count - 3]
      try screen.click(CGPoint(x: edit.midX, y: edit.midY))
      #expect(draft.value.trigger == nil)
      #expect(draft.value.prompt == "Rendered prompt")
      #expect(screen.textFields.contains { $0.stringValue == "Rendered prompt" })
    }

    @Test("no rendered prompt offers nothing to take over")
    func noPromptYet() throws {
      let screen = sheet(draft())
      defer { screen.close() }
      #expect(screen.buttonFrames.count == 2, "Add condition and Cancel")
    }

    @Test("a template with no fields can't add conditions")
    func noFields() throws {
      var bare = template
      bare.fields = []
      let screen = sheet(draft(), template: bare)
      defer { screen.close() }
      #expect(screen.buttonFrames.count == 1, "Cancel")
    }
  }
#endif
