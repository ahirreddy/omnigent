#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Policies, clicked", .serialized)
  @MainActor
  struct SettingsPoliciesTests {
    private let log = ActionLog()
    private let store: UserDefaults

    init() throws {
      store = try #require(UserDefaults(suiteName: "settings-policies-\(UUID())"))
    }

    private func actions(adds: Bool = true) -> ServerSettingsActions {
      var actions = ServerSettingsActions()
      let log = log
      actions.addPolicy = { template, name, values in
        let sorted = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        log.record("add \(template.id) [\(name)] \(sorted)")
        return adds
      }
      actions.setPolicyEnabled = { log.record("enabled \($0.id) \($1)") }
      actions.deletePolicy = { log.record("delete \($0.id)") }
      return actions
    }

    private var template: PolicyTemplate {
      PolicyTemplate(
        id: "budget", name: "Budget", detail: "Limits spend", suggestedName: "budget-1",
        params: [PolicyTemplate.Param(id: "limit", kind: .text, defaultValue: "10")])
    }

    @Test("the switch and Delete act on that policy, and Delete asks first")
    func rows() throws {
      let rows = [
        ServerSettingRow(id: "p1", name: "One", detail: "First"),
        ServerSettingRow(id: "p2", name: "Managed", isReadOnly: true),
      ]
      let actions = actions()
      let screen = settingsForm(store: store) { PoliciesPane(policies: rows, actions: actions) }
      defer { screen.close() }
      #expect(try screen.shows("From the server's config file"))
      let toggles = screen.switches
      try screen.click(toggles[0])
      #expect(log.entries == ["enabled p1 false"])
      try screen.click(toggles[1])
      #expect(log.entries.count == 1, "a managed policy can't change")
      // Add Policy, then this row's Delete; the managed row has none.
      let buttons = screen.buttonFrames
      #expect(buttons.count == 2)
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      try screen.clickButton(at: 1)
      #expect(SystemSideEffects.record.alertMessages == ["Remove One?"])
      #expect(log.entries.count == 1)
      SystemSideEffects.answer(alert: .alertFirstButtonReturn)
      try screen.clickButton(at: 1)
      #expect(log.entries.last == "delete p1")
    }

    @Test("no policies says so")
    func none() throws {
      let screen = settingsForm(store: store) {
        PoliciesPane(policies: [], actions: ServerSettingsActions())
      }
      defer { screen.close() }
      #expect(try screen.shows("No default policies."))
      #expect(screen.controlFrames.isEmpty)
    }

    private func addSheet(
      templates: [PolicyTemplate], adds: Bool = true, errorMessage: String? = nil
    ) throws -> OffscreenWindow<some View> {
      let actions = actions(adds: adds)
      let screen = settingsForm(store: store) {
        PoliciesPane(
          policies: [], templates: templates, actions: actions, errorMessage: errorMessage)
      }
      try screen.clickControl(at: 0)
      screen.settle(0.3)
      try #require(screen.window.attachedSheet != nil)
      return screen
    }

    /// In the sheet: a template's row is the first plain button; Cancel and Add end the footer.
    private func chooseFirst<Content>(_ screen: OffscreenWindow<Content>) throws {
      try screen.clickButton(at: 0)
      screen.settle(0.2)
    }

    @Test("choosing a template fills its suggested name and defaults, and Add sends them")
    func add() async throws {
      let screen = try addSheet(templates: [template])
      defer { screen.close() }
      try chooseFirst(screen)
      let name = try #require(screen.textFields.first)
      #expect(name.stringValue == "budget-1")
      let limit = try #require(screen.textFields.last)
      #expect(limit.stringValue == "10")
      try screen.replaceText(in: limit, with: "25")
      // Change Policy, Cancel, Add.
      try screen.clickButton(at: 2)
      try await screen.letTasksRun()
      screen.settle(0.3)
      #expect(log.entries == [#"add budget [budget-1] ["limit=25"]"#])
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("a policy can't be added with a blank name, and spaces aren't a name")
    func blankName() async throws {
      let screen = try addSheet(templates: [template])
      defer { screen.close() }
      try chooseFirst(screen)
      let name = try #require(screen.textFields.first)
      try screen.replaceText(in: name, with: "   ")
      // Change Policy, Cancel: Add is off.
      #expect(screen.buttonFrames.count == 2)
      try screen.replaceText(in: name, with: " kept ")
      try screen.clickButton(at: 2)
      try await screen.letTasksRun()
      #expect(log.entries.first?.contains("[kept]") == true, "\(log.entries)")
    }

    @Test("a refused policy stays open and always says something")
    func refused() async throws {
      let screen = try addSheet(templates: [template], adds: false)
      defer { screen.close() }
      try chooseFirst(screen)
      try screen.clickButton(at: 2)
      try await screen.letTasksRun()
      #expect(screen.window.attachedSheet != nil)
      #expect(log.entries.count == 1)
      #expect(try screen.shows("The policy could not be added."))
      let explained = try addSheet(templates: [template], adds: false, errorMessage: "Duplicate")
      defer { explained.close() }
      try chooseFirst(explained)
      try explained.clickButton(at: 2)
      try await explained.letTasksRun()
      #expect(try explained.shows("Duplicate"))
    }

    @Test("Change Policy goes back to the list, and the filter narrows it")
    func changeAndFilter() throws {
      let other = PolicyTemplate(
        id: "other", name: "Other", detail: "", suggestedName: "other-1", params: [])
      let screen = try addSheet(templates: [template, other])
      defer { screen.close() }
      let filter = try #require(screen.textFields.first)
      // Two template rows, then Cancel; Add is off.
      #expect(screen.buttonFrames.count == 3)
      try screen.replaceText(in: filter, with: "Bud")
      #expect(screen.buttonFrames.count == 2)
      try screen.replaceText(in: filter, with: "nothing")
      #expect(screen.buttonFrames.count == 1)
      #expect(try screen.shows("No policies match your filter."))
      try screen.replaceText(in: filter, with: "")
      try chooseFirst(screen)
      try screen.clickButton(at: 0)
      screen.settle(0.2)
      #expect(try screen.shows("Other"), "the whole list is back")
      #expect(try !screen.shows("Limits spend") == false)
    }

    @Test("every kind of parameter has its control and writes its value")
    func parameterKinds() async throws {
      typealias Param = PolicyTemplate.Param
      let template = PolicyTemplate(
        id: "kinds", name: "Kinds", detail: "", suggestedName: "kinds-1",
        params: [
          Param(id: "flag", kind: .boolean, detail: "A switch", defaultValue: "false"),
          Param(id: "pick", kind: .choice, defaultValue: "", options: ["x", "y"]),
          Param(id: "many", kind: .multiChoice, defaultValue: "", options: ["m", "n"]),
          Param(id: "list", kind: .list, defaultValue: ""),
          Param(id: "object", kind: .object, defaultValue: ""),
          Param(id: "count", kind: .integer, defaultValue: "1"),
        ])
      let screen = try addSheet(templates: [template])
      defer { screen.close() }
      try chooseFirst(screen)
      let toggles = screen.switches
      #expect(toggles.count == 3, "flag, m and n")
      try screen.set(toggles[0], isOn: true)
      try screen.set(toggles[2], isOn: true)
      try screen.set(toggles[1], isOn: true)
      try screen.set(toggles[2], isOn: false)
      try screen.choose("y", inPopUp: try #require(screen.popUps.first))
      #expect(screen.textFields.contains { $0.placeholderString == "JSON object" })
      #expect(screen.textFields.contains { $0.placeholderString == "Comma-separated" })
      try screen.clickButton(at: 2)
      try await screen.letTasksRun()
      let sent = try #require(log.entries.first)
      #expect(sent.contains("flag=true"), "\(sent)")
      #expect(sent.contains("many=m"), "\(sent)")
      #expect(sent.contains("pick=y"), "\(sent)")
    }

    @Test("no templates yet says Loading; a template repeated by the registry doesn't crash")
    func loadingAndRepeats() throws {
      let loading = try addSheet(templates: [])
      defer { loading.close() }
      #expect(try loading.shows("Loading policies\u{2026}"))
      let repeated = PolicyTemplate(
        id: "r", name: "R", detail: "", suggestedName: "r-1",
        params: [
          PolicyTemplate.Param(id: "same", kind: .text, defaultValue: "first"),
          PolicyTemplate.Param(id: "same", kind: .text, defaultValue: "second"),
        ])
      let screen = try addSheet(templates: [repeated])
      defer { screen.close() }
      try chooseFirst(screen)
      #expect(screen.textFields.last?.stringValue == "first")
    }
  }
#endif
