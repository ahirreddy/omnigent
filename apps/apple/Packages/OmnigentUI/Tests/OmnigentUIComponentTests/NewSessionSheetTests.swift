#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The sheet's inputs, which a test changes as the app's store would.
  @MainActor @Observable
  final class NewSessionSheetModel {
    var state: NewSessionViewState

    init(_ state: NewSessionViewState) { self.state = state }
  }

  /// Records what the sheet asks of its host.
  @MainActor
  final class NewSessionLog {
    var events: [String] = []
    var created: [Created] = []
    var changes: [CreationSelection] = []
    var unavailable: @MainActor (CreationSelection) -> String? = { _ in nil }

    struct Created {
      let selection: CreationSelection
      let title: String
      let message: String
    }

    func actions(reload: Bool = true, acknowledge: Bool = true) -> NewSessionActions {
      NewSessionActions(
        unavailableReason: { selection in self.unavailable(selection) },
        selectionChanged: { selection in self.changes.append(selection) },
        create: { selection, title, message in
          self.created.append(Created(selection: selection, title: title, message: message))
        },
        reload: reload ? recorder("reload") : nil,
        acknowledgeUncertain: acknowledge ? recorder("acknowledge") : nil,
        cancel: recorder("cancel"))
    }

    private func recorder(_ name: String) -> @MainActor () -> Void {
      { self.events.append(name) }
    }
  }

  /// The sheet presented as the app presents it, so its toolbar's buttons exist.
  struct NewSessionSheetScreen: View {
    @Bindable var model: NewSessionSheetModel
    let actions: NewSessionActions
    var initial = CreationSelection()

    var body: some View {
      Color.clear.sheet(isPresented: .constant(true)) {
        NewSessionView(state: model.state, actions: actions, initialSelection: initial)
      }
    }
  }

  /// The new-session sheet: where it runs, what's in it, and what Create sends.
  @Suite("New session sheet", .serialized)
  @MainActor
  struct NewSessionSheetTests {
    fileprivate let log = NewSessionLog()

    fileprivate static let catalog = CreationCatalog(
      hosts: [
        CreationHost(hostId: "mac", name: "Mac", status: "online"),
        CreationHost(hostId: "gone", name: "Old box", status: "offline"),
        CreationHost(hostId: "box", name: "Sandbox", status: "online", sandboxProvider: "e2b"),
      ],
      agents: [
        CreationAgent(id: "c1", name: "Claude One", harness: "claude", description: "Writes code"),
        CreationAgent(id: "x1", name: "", harness: "codex"),
        CreationAgent(id: "x2", name: "Codex Two", harness: "codex"),
        CreationAgent(id: "n1", name: "No harness"),
      ])

    fileprivate func open(
      _ state: NewSessionViewState = NewSessionViewState(catalog: .loaded(Self.catalog)),
      initial: CreationSelection = CreationSelection(),
      reload: Bool = true, acknowledge: Bool = true
    ) -> (OffscreenWindow<NewSessionSheetScreen>, NewSessionSheetModel) {
      let model = NewSessionSheetModel(state)
      let screen = OffscreenWindow(
        NewSessionSheetScreen(
          model: model, actions: log.actions(reload: reload, acknowledge: acknowledge),
          initial: initial))
      screen.settle(0.5)
      return (screen, model)
    }

    /// The confirm button, last in the sheet's toolbar while it's enabled.
    fileprivate func tapCreate(_ screen: OffscreenWindow<NewSessionSheetScreen>) throws {
      try screen.tapButton(fromEnd: 0)
    }

    /// Cancel, just before Create.
    private func tapCancel(_ screen: OffscreenWindow<NewSessionSheetScreen>) throws {
      try screen.tapButton(fromEnd: 1)
    }

    /// A disabled Create isn't listed, so the last button in the toolbar is Cancel.
    fileprivate func expectCreateDisabled(
      _ screen: OffscreenWindow<NewSessionSheetScreen>,
      sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
      log.events = []
      try tapCreate(screen)
      #expect(log.created.isEmpty, sourceLocation: sourceLocation)
      #expect(log.events == ["cancel"], sourceLocation: sourceLocation)
    }

    /// The picker labelled `name`: the form's pickers in order are host, harness, agent, model.
    private enum PickerRow: Int {
      case host, harness, agent
    }

    private func picker(
      _ row: PickerRow, _ screen: OffscreenWindow<NewSessionSheetScreen>
    ) throws -> NSMenu {
      try screen.menu(at: row.rawValue)
    }

    @Test("While the catalog loads the sheet says so, and Create does nothing")
    func loading() throws {
      for phase in [LoadPhase<CreationCatalog>.idle, .loading] {
        let (screen, _) = open(NewSessionViewState(catalog: phase))
        defer { screen.close() }
        #expect(try screen.shows("Loading hosts and agents"))
        try expectCreateDisabled(screen)
      }
    }

    @Test("A failed catalog says why and tries again; with no retry there's no button")
    func failedCatalog() throws {
      let (screen, _) = open(NewSessionViewState(catalog: .failed(message: "No route")))
      defer { screen.close() }
      #expect(try screen.shows("No route"))
      #expect(try screen.shows("Try Again"))
      let withRetry = screen.buttons.count
      // Try Again sits in the form, before Cancel; Create is disabled.
      try screen.tapButton(fromEnd: 1)
      #expect(log.events == ["reload"])

      let (bare, _) = open(
        NewSessionViewState(catalog: .failed(message: "No route")), reload: false)
      defer { bare.close() }
      #expect(try !bare.shows("Try Again"))
      #expect(bare.buttons.count == withRetry - 1)
    }

    @Test("Cancel closes the sheet")
    func cancel() throws {
      let (screen, _) = open()
      defer { screen.close() }
      try tapCancel(screen)
      #expect(log.events == ["cancel"])
    }

    @Test("The host picker marks hosts that can't run, and picking one clears what was on it")
    func hostPicker() throws {
      let (screen, _) = open(
        initial: CreationSelection(hostId: "mac", workspace: "/old", model: "fast"))
      defer { screen.close() }
      let menu = try picker(.host, screen)
      let titles = menu.items.map(\.title)
      #expect(titles.contains("Choose a host"))
      #expect(titles.contains { $0.contains("Old box") })
      try screen.choose(try #require(titles.first { $0.contains("Old box") }), in: menu)
      let change = try #require(log.changes.last)
      #expect(change.hostId == "gone")
      #expect(change.workspace.isEmpty)
      #expect(change.model == nil)
    }

    @Test("A harness narrows the agents, and picks a ready one when the chosen one is gone")
    func harnessPicker() throws {
      log.unavailable = { $0.agentId == "x1" ? "Not on this host" : nil }
      let (screen, _) = open(initial: CreationSelection(agentId: "c1"))
      defer { screen.close() }
      #expect(try screen.shows("Writes code"))
      let harnesses = try picker(.harness, screen)
      #expect(harnesses.items.map(\.title) == ["Any harness", "Claude Code", "Codex"])
      try screen.choose("Codex", in: harnesses)
      #expect(log.changes.last?.agentId == "x2")
      let agents = try picker(.agent, screen)
      // A nameless agent shows its id.
      #expect(agents.items.map(\.title) == ["Choose an agent", "x1", "Codex Two"])
      #expect(try !screen.shows("Writes code"))
    }

    @Test("With every agent unavailable the first is still chosen, so the reason shows")
    func harnessAllUnavailable() throws {
      log.unavailable = { _ in "Nothing can run" }
      let (screen, _) = open()
      defer { screen.close() }
      #expect(try screen.shows("Nothing can run"))
      try screen.choose("Codex", in: try picker(.harness, screen))
      #expect(log.changes.last?.agentId == "x1")
    }

    @Test("A harness that still has the chosen agent leaves it alone")
    func harnessKeepsAgent() throws {
      let (screen, _) = open(initial: CreationSelection(agentId: "x2"))
      defer { screen.close() }
      try screen.choose("Codex", in: try picker(.harness, screen))
      #expect(log.changes.isEmpty)
    }

    @Test("Picking an agent tells the host, and clears the model")
    func agentPicker() throws {
      let (screen, _) = open(initial: CreationSelection(model: "fast"))
      defer { screen.close() }
      try screen.choose("Claude One", in: try picker(.agent, screen))
      #expect(log.changes.last?.agentId == "c1")
      #expect(log.changes.last?.model == nil)
      #expect(try screen.shows("Writes code"))
    }

    @Test("Create sends the selection, title and first message as typed")
    func create() throws {
      let (screen, _) = open(initial: CreationSelection(hostId: "mac", agentId: "c1"))
      defer { screen.close() }
      #expect(screen.fields.count == 3)
      try screen.type("/src/app", intoField: 0)
      try screen.type("A title", intoField: 1)
      try screen.type("Fix it", intoField: 2)
      screen.settle(0.05)
      try tapCreate(screen)
      let created = try #require(log.created.first)
      #expect(created.selection.hostId == "mac")
      #expect(created.selection.agentId == "c1")
      #expect(created.selection.workspace == "/src/app")
      #expect(created.title == "A title")
      #expect(created.message == "Fix it")
    }

    @Test("Why Create is disabled shows, and it stays disabled")
    func blocked() throws {
      log.unavailable = { _ in "Choose a host first." }
      let (screen, _) = open()
      defer { screen.close() }
      #expect(try screen.shows("Choose a host first."))
      try expectCreateDisabled(screen)
    }

    @Test("A title over the limit blocks Create")
    func longTitle() throws {
      let (screen, _) = open()
      defer { screen.close() }
      try screen.type(String(repeating: "t", count: 121), intoField: 1)
      screen.settle(0.05)
      #expect(try screen.shows("Titles can be up to 120 characters."))
      try expectCreateDisabled(screen)
    }

  }

  extension NewSessionSheetTests {
    // MARK: Folders and models

    @Test("The folder menu fills in the workspace")
    func workspaces() throws {
      let folders = [CreationWorkspace(path: "/src/one", name: "one")]
      let (screen, _) = open(
        NewSessionViewState(catalog: .loaded(Self.catalog), workspaces: .loaded(folders)))
      defer { screen.close() }
      // The model picker is last, the folder menu just before it.
      let menu = try screen.menu(at: 3)
      try screen.choose("/src/one", in: menu)
      #expect(screen.fields.first?.stringValue == "/src/one")
    }

    @Test("Folders that are loading or failed each say so, and typing still works")
    func workspaceStates() throws {
      let (failed, _) = open(
        NewSessionViewState(catalog: .loaded(Self.catalog), workspaces: .failed(message: "Denied."))
      )
      defer { failed.close() }
      #expect(try failed.shows("Folders could not be loaded: Denied. Enter an absolute path."))

      let (loading, _) = open(
        NewSessionViewState(catalog: .loaded(Self.catalog), workspaces: .loading))
      defer { loading.close() }
      #expect(loading.allViews.contains { $0 is NSProgressIndicator })
      #expect(try !loading.shows("Choose a Folder"))
    }

    @Test("Only models that aren't hidden are offered, and the choice is what's sent")
    func models() throws {
      let models = [
        ModelOption(id: "fast-id", model: "fast", displayName: "Fast"),
        ModelOption(id: "slow", displayName: "Slow"),
        ModelOption(id: "secret", displayName: "Secret", hidden: true),
      ]
      let (screen, _) = open(
        NewSessionViewState(catalog: .loaded(Self.catalog), models: .loaded(models)))
      defer { screen.close() }
      let menu = try screen.menu(at: 3)
      #expect(menu.items.map(\.title) == ["Harness default", "Fast", "Slow"])
      try screen.choose("Fast", in: menu)
      try tapCreate(screen)
      #expect(log.created.first?.selection.model == "fast")
    }

    @Test("Models that are loading or failed each say so")
    func modelStates() throws {
      let (loading, _) = open(NewSessionViewState(catalog: .loaded(Self.catalog), models: .loading))
      defer { loading.close() }
      #expect(try loading.shows("Loading models"))

      let (failed, _) = open(
        NewSessionViewState(catalog: .loaded(Self.catalog), models: .failed(message: "Timed out")))
      defer { failed.close() }
      #expect(try failed.shows("Models could not be loaded: Timed out"))
    }

    // MARK: The request

    @Test("While creating, nothing can be changed or sent twice")
    func creating() throws {
      let (screen, _) = open(
        NewSessionViewState(catalog: .loaded(Self.catalog), phase: .creating))
      defer { screen.close() }
      #expect(try screen.shows("Creating the session"))
      #expect(try !screen.shownText().contains("Create"))
      try screen.clickEveryButton()
      #expect(log.created.isEmpty)
      #expect(log.events.isEmpty)
    }

    @Test("A rejection says why and can be tried again")
    func failedRequest() throws {
      let (screen, _) = open(
        NewSessionViewState(catalog: .loaded(Self.catalog), phase: .failed(message: "Refused")))
      defer { screen.close() }
      #expect(try screen.shows("Refused"))
      try tapCreate(screen)
      #expect(log.created.count == 1)
    }

    @Test("An uncertain result blocks another until the user has checked")
    func uncertain() throws {
      let (screen, model) = open(
        NewSessionViewState(catalog: .loaded(Self.catalog), phase: .uncertain(message: "Lost it")))
      defer { screen.close() }
      #expect(try screen.shows("Lost it"))
      #expect(try screen.shows("I Checked Sessions, Allow Another"))
      // It's the form's last row, below the fold of a sheet this size.
      screen.scrollToEnd()
      try expectCreateDisabled(screen)
      try screen.tapButton(fromEnd: 1)
      #expect(log.events == ["cancel", "acknowledge"])
      model.state.phase = .editing
      screen.settle()
      try tapCreate(screen)
      #expect(log.created.count == 1)
    }

    @Test("With no way to acknowledge, an uncertain result only says so")
    func uncertainNoAcknowledge() throws {
      let (screen, _) = open(
        NewSessionViewState(catalog: .loaded(Self.catalog), phase: .uncertain(message: "Lost it")),
        acknowledge: false)
      defer { screen.close() }
      #expect(try !screen.shows("I Checked Sessions, Allow Another"))
    }
  }
#endif
