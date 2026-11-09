#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @MainActor
  @Observable
  private final class SettingsHost {
    var draft = ProjectSettingsDraft()
    var calls: [String] = []
  }

  private struct SettingsHarness: View {
    let host: SettingsHost
    let state: ProjectSettingsViewState

    var body: some View {
      Color.clear.sheet(isPresented: .constant(true)) {
        ProjectSettingsSheet(
          state: state, draft: Binding(get: { host.draft }, set: { host.draft = $0 }),
          actions: ProjectSettingsActions(
            save: { host.calls.append("save") }, cancel: { host.calls.append("cancel") }))
      }
    }
  }

  @Suite("Session list: project settings", .serialized)
  @MainActor
  struct SessionListProjectSettingsTests {
    private func sheet(_ host: SettingsHost, _ state: ProjectSettingsViewState)
      -> OffscreenWindow<AnyView>
    {
      OffscreenWindow(AnyView(SettingsHarness(host: host, state: state)), width: 700, height: 700)
    }

    private var loaded: ProjectSettingsViewState {
      var state = ProjectSettingsViewState(projectName: "Work", phase: .loaded)
      state.hosts = [ProjectSettingsChoice(id: "mac", title: "My Mac")]
      state.agents = [ProjectSettingsChoice(id: "a", title: "Agent A")]
      state.models = [ProjectSettingsChoice(id: "m", title: "Model M")]
      state.efforts = [ProjectSettingsChoice(id: "high", title: "High")]
      return state
    }

    @Test("While loading there's a spinner, no fields, and Save is off")
    func loading() throws {
      let host = SettingsHost()
      let screen = sheet(host, ProjectSettingsViewState(projectName: "Work", phase: .loading))
      defer { screen.close() }
      #expect(try screen.shows("Project Settings"))
      #expect(try !screen.shows("Random worktree"))
      #expect(screen.pickers.isEmpty)
    }

    @Test("A failed read says why and that Save is off so nothing is overwritten")
    func failed() throws {
      let host = SettingsHost()
      let screen = sheet(
        host, ProjectSettingsViewState(projectName: "Work", phase: .failed("boom")))
      defer { screen.close() }
      #expect(try screen.shows(containing: "boom"))
      #expect(try screen.shows(containing: "Saving is off"))
      #expect(try !screen.shows("Random worktree"))
    }

    @Test("A folder host asks for a working directory; no host says to pick one first")
    func workingDirectory() throws {
      var state = loaded
      let noHost = SettingsHost()
      let empty = sheet(noHost, state)
      defer { empty.close() }
      #expect(try empty.shows("Pick a host first"))
      #expect(try empty.shows("Where new sessions run by default."))

      state.hostTakesFolder = true
      let host = SettingsHost()
      let filling = sheet(host, state)
      defer { filling.close() }
      #expect(try !filling.shows("Pick a host first"))
      try filling.click(#require(filling.firstTextField))
      try filling.type("/repo")
      #expect(host.draft.workspace == "/repo")

      // A host chosen that takes no folder has nothing to ask.
      state.hostTakesFolder = false
      let chosen = SettingsHost()
      chosen.draft.hostID = "mac"
      let without = sheet(chosen, state)
      defer { without.close() }
      #expect(try !without.shows("Pick a host first"))
      #expect(without.firstTextField == nil)
    }

    @Test("The host and agent pickers offer No default and the choices, and store the pick")
    func pickers() throws {
      let host = SettingsHost()
      let screen = sheet(host, loaded)
      defer { screen.close() }
      #expect(screen.pickers.count == 2)
      let menu = try screen.openMenu(screen.pickers[0])
      #expect(menu.titles == ["No default", "My Mac"])
      try screen.choose("My Mac", in: menu)
      #expect(host.draft.hostID == "mac")
      try screen.pick("Agent A", in: screen.pickers[1])
      #expect(host.draft.agentID == "a")
      try screen.pick("No default", in: screen.pickers[1])
      #expect(host.draft.agentID == nil)
    }

    @Test("Model and effort show only when the agent has them")
    func modelAndEffort() throws {
      var state = loaded
      state.showsModel = true
      let modelOnly = SettingsHost()
      let first = sheet(modelOnly, state)
      defer { first.close() }
      #expect(first.pickers.count == 3)
      try first.pick("Model M", in: first.pickers[2])
      #expect(modelOnly.draft.model == "m")

      state.showsEffort = true
      let both = SettingsHost()
      let second = sheet(both, state)
      defer { second.close() }
      #expect(second.pickers.count == 4)
      try second.pick("High", in: second.pickers[3])
      #expect(both.draft.effort == "high")
    }

    @Test("Random worktree reveals the base branch")
    func worktree() throws {
      let host = SettingsHost()
      let screen = sheet(host, loaded)
      defer { screen.close() }
      #expect(screen.firstTextField == nil)
      let toggle = try #require(screen.allViews.lazy.compactMap { $0 as? NSSwitch }.first)
      let frame = toggle.convert(toggle.bounds, to: screen.activeWindow.contentView)
      try screen.click(CGPoint(x: frame.maxX - 2, y: frame.midY))
      #expect(host.draft.useWorktree)
      try screen.click(#require(screen.firstTextField))
      try screen.type("main")
      #expect(host.draft.baseBranch == "main")
    }

    @Test("Cancel and Save tell the host")
    func buttons() throws {
      let host = SettingsHost()
      let screen = sheet(host, loaded)
      defer { screen.close() }
      // The bar is last: Cancel, then Save.
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(host.calls == ["save"])
      try screen.clickControl(at: screen.controlFrames.count - 2)
      #expect(host.calls == ["save", "cancel"])
    }

    @Test("Save is off while saving, loading, or after a failed read; Cancel still works")
    func saveDisabled() throws {
      var saving = loaded
      saving.isSaving = true
      let states = [
        saving, ProjectSettingsViewState(projectName: "Work", phase: .loading),
        ProjectSettingsViewState(projectName: "Work", phase: .failed("boom")),
      ]
      for state in states {
        let host = SettingsHost()
        let screen = sheet(host, state)
        defer { screen.close() }
        // With Save disabled, the last control is Cancel.
        try screen.clickControl(at: screen.controlFrames.count - 1)
        #expect(host.calls == ["cancel"])
      }
    }

    @Test("A failed save shows its reason")
    func saveError() throws {
      var state = loaded
      state.saveError = "Couldn't save"
      let screen = sheet(SettingsHost(), state)
      defer { screen.close() }
      #expect(try screen.shows("Couldn't save"))
    }
  }
#endif
