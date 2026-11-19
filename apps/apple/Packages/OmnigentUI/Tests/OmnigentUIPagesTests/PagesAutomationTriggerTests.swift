#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

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

    /// Picks the Trigger (0) or Instructions (1) tab.
    private func tab<Content>(_ index: Int, _ screen: OffscreenWindow<Content>) throws {
      try screen.click(segment: index, of: try #require(screen.segmentedControls.first))
    }

    @Test("the event and scope write back; a new trigger picks its session continuity")
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
      #expect(screen.popUps.allSatisfy { $0.title != "New session each run" }, "it keeps one")
      try screen.clickElement("automation-advanced")
      try screen.choose(
        "One task session for all matches",
        inPopUp: try #require(screen.popUps.first { $0.title == "New session for each match" }))
      #expect(draft.value.trigger?.taskSession == true)
    }

    @Test("a trigger can't be saved until its prompt renders")
    func saveNeedsPrompt() throws {
      let draft = draft()
      let blocked = sheet(draft)
      defer { blocked.close() }
      // A disabled Save isn't a control: it sits just after Cancel, the last one.
      let cancel = try #require(blocked.controlFrames.last)
      try blocked.click(CGPoint(x: cancel.maxX + 30, y: cancel.midY))
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
      try screen.clickElement("automation-trigger-add-condition")
      let added = try #require(draft.value.trigger?.conditions.first)
      #expect(added.field == "assignee")
      #expect(added.operation == "unassigned")
      #expect(
        screen.textFields.allSatisfy { $0.placeholderString != "name" },
        "is unassigned has no value")
      #expect(try screen.shows("and"), "the row reads as the web's \u{201C}and\u{201D}")
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
      #expect(try screen.shows("Fill in or remove each condition."))
      let value = try #require(screen.textFields.first { $0.placeholderString == "name" })
      try screen.replaceText(in: value, with: "ahir")
      #expect(draft.value.trigger?.conditions.first?.value == "ahir")
      #expect(try !screen.shows("Fill in or remove each condition."))

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
      try screen.clickElement("automation-trigger-remove-\(first.id)")
      #expect(draft.value.trigger?.conditions.map(\.id) == [second.id])
    }

    @Test("the Instructions tab holds what each session gets; too-long ones say so on both tabs")
    func instructions() throws {
      let draft = draft()
      let screen = sheet(draft)
      defer { screen.close() }
      let tabs = try #require(screen.segmentedControls.first)
      #expect(tabs.label(forSegment: 1) == "Instructions *", "empty ones are marked, as the web's")
      #expect(screen.textFields.allSatisfy { $0.placeholderString != "What each session does" })
      try tab(1, screen)
      let field = try #require(
        screen.textFields.first { $0.placeholderString == "What each session does" })
      try screen.replaceText(in: field, with: "0123456789")
      #expect(try !screen.shows("Keep instructions to"))
      try screen.type("x")
      #expect(draft.value.trigger?.instructions == "0123456789x")
      #expect(try screen.shows("Keep instructions to 10 characters or fewer"))
      try tab(0, screen)
      #expect(try screen.shows("Edit instructions"), "the Trigger tab says so too")
      #expect(draft.value.trigger?.linkBack == true)
      try screen.click(try #require(screen.switches.last))
      #expect(draft.value.trigger?.linkBack == false)
    }

    @Test("Edit as a prompt takes over the rendered text and leaves the trigger")
    func editAsPrompt() throws {
      let draft = draft()
      let screen = sheet(draft, prompt: "Rendered prompt")
      defer { screen.close() }
      try tab(1, screen)
      try screen.clickElement("automation-trigger-edit-prompt")
      #expect(draft.value.trigger == nil)
      #expect(draft.value.prompt == "Rendered prompt")
      #expect(screen.textFields.contains { $0.stringValue == "Rendered prompt" })
    }

    @Test("the prompt each run sends stays folded away until its disclosure is clicked")
    func promptDisclosure() throws {
      let screen = sheet(draft(), prompt: "Rendered prompt")
      defer { screen.close() }
      try tab(1, screen)
      #expect(try !screen.shows("Rendered prompt"))
      // The disclosure leads the Instructions tab's buttons.
      try screen.click(try #require(screen.buttonFrames.first).center)
      screen.settle(0.3)
      #expect(try screen.shows("Rendered prompt"))
    }

    @Test("no rendered prompt offers nothing to take over")
    func noPromptYet() throws {
      let screen = sheet(draft())
      defer { screen.close() }
      try tab(1, screen)
      #expect(try !screen.shows("Edit as a prompt"))
      #expect(try !screen.shows("Prompt each run sends"))
    }

    @Test("a template with no fields can't add conditions")
    func noFields() throws {
      var bare = template
      bare.fields = []
      let screen = sheet(draft(), template: bare)
      defer { screen.close() }
      #expect(try !screen.shows("Add condition"))
    }

  }

  extension PagesAutomationTriggerTests {
    @Test("the card warns about the source and the tools a run needs, as the web's tags")
    func warnings() throws {
      var described = template
      described.serviceName = "Jira"
      described.toolsExample = "a Jira MCP server"
      described.eventDetails = [
        "created": .init(
          description: "Starts a session for each new ticket. Checks look back to the last one.",
          scopeLabel: "project", scopePlaceholder: "ENG",
          authorAction: "create a ticket in these projects")
      ]
      let screen = sheet(draft(), template: described)
      defer { screen.close() }
      #expect(try screen.shows("Starts a session for each new ticket."))
      #expect(try !screen.shows("Checks look back"), "the rest waits under the info button")
      #expect(try screen.shows("MCP required"))
      #expect(try screen.shows("Untrusted source"))
      #expect(try screen.shows("Project"))
    }

    @Test("the Trigger tab keeps the web's order: tabs, event, scope, conditions, link-back")
    func builderLayout() throws {
      let condition = AutomationTriggerCondition(field: "label", operation: "has")
      let screen = sheet(draft(conditions: [condition]))
      defer { screen.close() }
      let order = [
        "automation-trigger-tabs", "automation-trigger-event", "automation-trigger-scope",
        "automation-trigger-condition-\(condition.id)", "automation-trigger-add-condition",
        "automation-trigger-link-back", "automation-host",
      ]
      let frames = try screen.withAccessibilityTree {
        try order.map { try screen.accessibilityFrame($0) }
      }
      for (above, below) in zip(frames, frames.dropFirst()) {
        #expect(above.maxY <= below.minY + 1, "\(above) is above \(below)")
      }
    }
  }
#endif
