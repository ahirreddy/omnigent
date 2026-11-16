#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The composer's menus chosen from, and the command that opens the approval dialog typed and
  /// sent, each checked by what the host was then asked to do.
  @Suite("Composer: menus and typed commands", .serialized)
  @MainActor
  struct ComposerMenuActionTests {
    private let log = ComposerActionLog()
    private static let file = URL(fileURLWithPath: "/tmp/copied.txt")
    private static let shortcutHint = "Option-Command-Return"

    init() {
      SystemSideEffects.reset()
    }

    // MARK: The Send button's menu

    /// The Send button's context menu: the one that names the other way's keys.
    private func sendMenu(_ screen: OffscreenWindow<ComposerScreen>) throws -> NSMenu? {
      for frame in screen.buttons {
        guard let menu = try screen.contextMenu(at: screen.clickPoint(frame)) else { continue }
        if menu.items.contains(where: { $0.title == Self.shortcutHint }) { return menu }
      }
      return nil
    }

    private func chooseAlternative(
      in menu: NSMenu, on screen: OffscreenWindow<ComposerScreen>
    ) throws {
      let other = try #require(
        menuTitles(menu).first { $0 != Self.shortcutHint }, "\(menuTitles(menu))")
      try screen.choose(other, in: menu)
    }

    @Test("mid-turn, the Send button's menu queues the draft instead of steering")
    func sendMenuQueues() throws {
      var state = ComposerViewState()
      state.isRunning = true
      state.canSteer = true
      let screen = openComposer(ComposerScreenModel(draft: "more", state: state), log.actions)
      defer { screen.close() }
      let menu = try #require(try sendMenu(screen))
      try chooseAlternative(in: menu, on: screen)
      #expect(log.events == ["queueDraft"])
    }

    @Test("with messages queued, the Send button's menu sends now instead of queueing")
    func sendMenuSteers() throws {
      var state = ComposerViewState()
      state.isRunning = true
      state.canSteer = true
      state.queue = [QueuedMessage(id: "q", text: "first")]
      let screen = openComposer(ComposerScreenModel(draft: "more", state: state), log.actions)
      defer { screen.close() }
      let menu = try #require(try sendMenu(screen))
      try chooseAlternative(in: menu, on: screen)
      #expect(log.events == ["send"])
    }

    @Test("an idle composer's Send has no other way to offer")
    func sendMenuIdle() throws {
      let screen = openComposer(
        ComposerScreenModel(draft: "more", state: ComposerViewState()), log.actions)
      defer { screen.close() }
      #expect(try sendMenu(screen) == nil)
    }

    // MARK: The Add menu

    @Test("Paste in the Add menu attaches the copied file")
    func addMenuPastes() async throws {
      let pasteboard = SystemSideEffects.pasteboard
      pasteboard.clearContents()
      pasteboard.setString(Self.file.absoluteString, forType: .fileURL)
      let screen = openComposer(ComposerScreenModel(state: ComposerViewState()), log.actions)
      defer { screen.close() }
      let menu = try screen.menu(at: 0)
      let paste = try #require(
        menu.items.first { $0.title == "Paste" }, "\(menuTitles(menu))")
      #expect(paste.isEnabled)
      try screen.choose("Paste", in: menu)
      #expect(try await screen.eventually { !log.attachments.isEmpty })
      #expect(log.attachments == [.file(url: Self.file)])
    }

    // MARK: A queued message's menu

    @Test("a queued message's menu sends it now, removes it, and opens it for editing")
    func queueRowMenu() throws {
      var state = ComposerViewState()
      state.queue = [
        QueuedMessage(id: "one", text: "first"), QueuedMessage(id: "two", text: "second"),
      ]
      state.isRunning = true
      state.canSteer = true
      let screen = openComposer(ComposerScreenModel(state: state), log.actions)
      defer { screen.close() }
      // The second row's buttons follow the first row's three.
      let row = try #require(screen.buttons.dropFirst(3).first)
      let menu = try #require(try screen.contextMenu(at: screen.clickPoint(row)))
      try screen.choose("Send now", in: menu)
      try screen.choose("Remove", in: menu)
      #expect(log.events == ["sendNow:two", "remove:two"])

      #expect(!screen.fields.contains { $0.stringValue == "second" })
      try screen.choose("Edit", in: menu)
      #expect(screen.fields.contains { $0.stringValue == "second" }, "its text is in a field")
      try screen.pressReturn()
      #expect(log.events == ["sendNow:two", "remove:two", "edit:two:second"])
    }

    // MARK: /permissions

    /// A composer whose send does the store's part for `/permissions`: it takes the command out
    /// of the draft and asks for the approval dialog.
    private func permissionsComposer() -> (OffscreenWindow<ComposerScreen>, ComposerScreenModel) {
      let model = ComposerScreenModel(
        state: ComposerViewState(approvalModes: ComposerSamples.codexModes()))
      var actions = log.actions
      actions.send = {
        guard model.draft == "/permissions" else { return }
        model.draft = ""
        model.state.approvalPickerRequest += 1
      }
      return (openComposer(model, actions), model)
    }

    @Test("/permissions, typed and sent, asks which mode and switches to the answer")
    func permissionsCommand() throws {
      SystemSideEffects.answer(alert: .alertThirdButtonReturn)
      let (screen, model) = permissionsComposer()
      defer { screen.close() }
      try screen.type("/permissions")
      try screen.pressReturn()
      #expect(MainLoop.settle(until: { log.events == ["mode:full-access"] }))
      #expect(SystemSideEffects.record.alertMessages == ["Codex approvals"])
      #expect(model.draft.isEmpty)
    }

    @Test("Cancel in the approval dialog switches nothing")
    func permissionsCancelled() throws {
      // The dialog's buttons: Codex's three modes, then Cancel.
      let cancel = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3
      SystemSideEffects.answer(alert: NSApplication.ModalResponse(rawValue: cancel))
      let (screen, _) = permissionsComposer()
      defer { screen.close() }
      try screen.type("/permissions")
      try screen.pressReturn()
      #expect(
        MainLoop.settle(until: { SystemSideEffects.record.alertMessages == ["Codex approvals"] }))
      #expect(log.events.isEmpty)
    }
  }
#endif
