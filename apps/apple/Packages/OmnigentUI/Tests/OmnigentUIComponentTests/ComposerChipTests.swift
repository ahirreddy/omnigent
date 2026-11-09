#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The row under the pill: host, folder, worktree, model and effort, approval mode. Each opens
  /// a real menu and each item is chosen through it.
  @Suite("Composer: chips and their menus", .serialized)
  @MainActor
  struct ComposerChipTests {
    private let log = ComposerActionLog()

    private func item(_ title: String, in menu: NSMenu) -> NSMenuItem? {
      for item in menu.items {
        if item.title == title { return item }
        if let submenu = item.submenu, let found = self.item(title, in: submenu) { return found }
      }
      return nil
    }

    @Test("the approval chip lists its modes, marks the current one and switches on a click")
    func approvalMenu() throws {
      let model = ComposerScreenModel(
        state: ComposerViewState(approvalModes: ComposerSamples.codexModes()))
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      let menu = try screen.chip(0)
      #expect(
        menuTitles(menu) == [
          "Codex approvals", "Auto-edit", "Auto-approve", "Full access",
          "Shift-Tab switches modes. The sandbox and model are separate.",
        ])
      try screen.choose("Full access", in: menu)
      #expect(log.events == ["mode:full-access"])
    }

    @Test("a launch-only mode can't be chosen; the current one stays listed")
    func launchOnlyMode() throws {
      let modes = ApprovalModes(
        options: [
          ApprovalModeOption(id: "a", label: "Ask first", risk: .ask),
          ApprovalModeOption(id: "b", label: "Locked", risk: .readOnly, isSwitchable: false),
          ApprovalModeOption(id: "c", label: "Stuck", risk: .fullAccess, isSwitchable: false),
        ], selectedID: "c")
      let model = ComposerScreenModel(state: ComposerViewState(approvalModes: modes))
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      let menu = try screen.chip(0)
      #expect(item("Locked", in: menu)?.isEnabled == false)
      #expect(item("Stuck", in: menu)?.isEnabled == true)
      #expect(item("Ask first", in: menu)?.isEnabled == true)
    }

    @Test("without a way to switch, the approval chip takes no clicks")
    func approvalReadOnly() throws {
      var actions = log.actions
      actions.extras.selectApprovalMode = nil
      let model = ComposerScreenModel(
        state: ComposerViewState(approvalModes: ComposerSamples.codexModes()))
      let screen = openComposer(model, actions)
      defer { screen.close() }
      #expect(screen.chips.isEmpty)
    }

    @Test("an unavailable composer's chips take no clicks")
    func chipsDisabledWhenUnavailable() throws {
      var state = ComposerViewState(
        configuration: ComposerSamples.codexConfiguration,
        approvalModes: ComposerSamples.codexModes())
      state.availability = .unavailable(reason: "Archived")
      let model = ComposerScreenModel(state: state)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      #expect(screen.chips.isEmpty)
    }

    // MARK: Model, effort, agent

    @Test("the model menu offers agents, models and efforts, and each one selects")
    func configurationMenu() throws {
      let model = ComposerScreenModel(
        state: ComposerViewState(configuration: ComposerSamples.codexConfiguration))
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      let menu = try screen.chip(0)
      #expect(item("Pi", in: menu)?.isEnabled == false, "not signed in on the host")
      try screen.choose("Claude Code", in: menu)
      try screen.choose("GPT-5.2", in: menu)
      try screen.choose("Default (GPT-5.2 Codex)", in: menu)
      try screen.choose("Low", in: menu)
      try screen.choose("Default (Medium)", in: menu)
      #expect(
        log.events == [
          "agent:agent_claude", "model:gpt-5.2", "model:default", "effort:low", "effort:default",
        ])
    }

    @Test("an agent list with no selection handler, models or efforts leaves those out")
    func configurationMenuReduces() throws {
      var actions = log.actions
      actions.selectAgent = nil
      actions.selectModel = nil
      actions.selectEffort = nil
      let model = ComposerScreenModel(
        state: ComposerViewState(configuration: ComposerSamples.codexConfiguration))
      let screen = openComposer(model, actions)
      defer { screen.close() }
      let menu = try screen.chip(0)
      #expect(menuTitles(menu).isEmpty)
    }

    @Test("a model list that failed says so in the menu")
    func configurationError() throws {
      var configuration = ComposerSamples.codexConfiguration
      configuration.errorMessage = "Models unavailable."
      let model = ComposerScreenModel(state: ComposerViewState(configuration: configuration))
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      #expect(menuTitles(try screen.chip(0)).contains("Models unavailable."))
    }

    @Test("while a change applies the chip waits, and takes no clicks")
    func configurationApplying() throws {
      var configuration = ComposerSamples.codexConfiguration
      configuration.isApplying = true
      let model = ComposerScreenModel(state: ComposerViewState(configuration: configuration))
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      #expect(screen.allViews.contains { $0 is NSProgressIndicator })
      #expect(screen.chips.isEmpty)
    }

    @Test("grouped agents sit under Harnesses and Agents, with the rest in the Other submenus")
    func groupedAgents() throws {
      var configuration = ComposerConfiguration(
        harnessChoices: [
          HarnessChoice(id: "codex", name: "Codex", harness: "codex-native"),
          HarnessChoice(id: "pi", name: "Pi", harness: "pi-native"),
          HarnessChoice(id: "polly", name: "Polly"),
          HarnessChoice(id: "mine", name: "Mine"),
        ], selectedAgentId: "mine")
      configuration.agentGroups = [
        "codex": .harness, "pi": .otherHarness, "polly": .agent, "mine": .custom,
      ]
      let model = ComposerScreenModel(state: ComposerViewState(configuration: configuration))
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      let menu = try screen.chip(0)
      let titles = menuTitles(menu)
      #expect(titles.contains("Harnesses"))
      #expect(titles.contains("Agents"))
      #expect(titles.contains("Other\u{2026}"), "Pi isn't the selected agent")
      #expect(titles.contains("Other\u{2026} (Mine)"), "the submenu names the selection inside it")
      try screen.choose("Pi", in: menu)
      try screen.choose("Polly", in: menu)
      try screen.choose("Create Custom Agent\u{2026}", in: menu)
      try screen.choose("Import Bundle\u{2026}", in: menu)
      #expect(log.events == ["agent:pi", "agent:polly", "createAgent", "importBundle"])
    }

    @Test("with no custom agents, Other still offers to create one")
    func groupedAgentsCreateOnly() throws {
      var configuration = ComposerConfiguration(
        harnessChoices: [HarnessChoice(id: "polly", name: "Polly")], selectedAgentId: "polly")
      configuration.agentGroups = ["polly": .agent]
      var actions = log.actions
      actions.extras.importAgentBundle = nil
      let model = ComposerScreenModel(state: ComposerViewState(configuration: configuration))
      let screen = openComposer(model, actions)
      defer { screen.close() }
      let titles = menuTitles(try screen.chip(0))
      #expect(titles.contains("Create Custom Agent\u{2026}"))
      #expect(!titles.contains("Import Bundle\u{2026}"))
      #expect(!titles.contains("Harnesses"))
    }

    @Test("Smart Routing toggles from the menu and locks the effort while it's on")
    func smartRouting() throws {
      var configuration = ComposerSamples.codexConfiguration
      configuration.smartRouting = .disabled
      let disabled = ComposerScreenModel(state: ComposerViewState(configuration: configuration))
      let offScreen = openComposer(disabled, log.actions)
      defer { offScreen.close() }
      let offMenu = try offScreen.chip(0)
      #expect(item("Low", in: offMenu)?.isEnabled == true)
      try offScreen.choose(ComposerConfiguration.smartRoutingTitle, in: offMenu)
      #expect(log.events == ["smartRouting:true"])

      log.events = []
      configuration.smartRouting = .enabled
      let enabled = ComposerScreenModel(state: ComposerViewState(configuration: configuration))
      let onScreen = openComposer(enabled, log.actions)
      defer { onScreen.close() }
      let onMenu = try onScreen.chip(0)
      #expect(item("Low", in: onMenu)?.isEnabled == false)
      try onScreen.choose(ComposerConfiguration.smartRoutingTitle, in: onMenu)
      #expect(log.events == ["smartRouting:false"])
    }
  }
#endif
