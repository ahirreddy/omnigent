#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// What the share and fork sheets ask for.
  @MainActor
  final class SheetLog {
    var calls: [String] = []
    var choices: ForkChoices?
  }

  extension OffscreenWindow {
    /// The menu-style pickers and menus, in view order.
    var pickers: [NSPopUpButton] { allViews.compactMap { $0 as? NSPopUpButton } }

    /// Picks an item in the picker.
    func pick(_ title: String, in picker: NSView) throws {
      try choose(title, in: try openMenu(picker))
    }
  }

  @Suite("Inspector: the share sheet", .serialized)
  @MainActor
  struct InspectorShareSheetTests {
    private let ada = ShareGrant(id: "ada", principal: "ada@example.com", role: .read)

    private func actions(_ log: SheetLog) -> ShareActions {
      ShareActions(
        setGeneralAccess: { log.calls.append("access \($0)") },
        setWorkspaceFiles: { log.calls.append("files \($0)") },
        addGrant: { log.calls.append("add \($0) \($1.rawValue)") },
        setRole: { log.calls.append("role \($0.id) \($1.rawValue)") },
        removeGrant: { log.calls.append("remove \($0.id)") })
    }

    private func sheet(_ state: ShareViewState, _ actions: ShareActions, log: SheetLog)
      -> OffscreenWindow<AnyView>
    {
      SystemSideEffects.reset()
      let view = Color.clear.sheet(isPresented: .constant(true)) {
        ShareSheet(state: state, actions: actions) { log.calls.append("done") }
      }
      return OffscreenWindow(AnyView(view), width: 700, height: 700)
    }

    @Test("With no grants it says so; Done closes")
    func empty() throws {
      let log = SheetLog()
      let screen = sheet(ShareViewState(), actions(log), log: log)
      defer { screen.close() }
      #expect(try screen.shows("Share this session"))
      #expect(try screen.shows("No grants yet."))
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(log.calls == ["done"])
    }

    @Test("General access is a picker of its options")
    func generalAccess() throws {
      let log = SheetLog()
      let screen = sheet(ShareViewState(), actions(log), log: log)
      defer { screen.close() }
      let picker = try #require(screen.pickers.first)
      try screen.pick("Anyone in the workspace can view", in: picker)
      #expect(log.calls == ["access Anyone in the workspace can view"])
    }

    @Test("Without the action general access can't change")
    func generalAccessDisabled() throws {
      let log = SheetLog()
      let screen = sheet(ShareViewState(), ShareActions(), log: log)
      defer { screen.close() }
      #expect(try #require(screen.pickers.first).isEnabled == false)
    }

    @Test("Workspace files is a switch, shown only when the server can store it")
    func workspaceFiles() throws {
      let log = SheetLog()
      let screen = sheet(ShareViewState(), actions(log), log: log)
      defer { screen.close() }
      #expect(try screen.shows("Workspace files"))
      let toggle = try #require(screen.allViews.compactMap { $0 as? NSSwitch }.first)
      let frame = toggle.convert(toggle.bounds, to: screen.activeWindow.contentView)
      try screen.click(CGPoint(x: frame.maxX - 3, y: frame.midY))
      #expect(log.calls == ["files true"])
      let without = sheet(ShareViewState(), ShareActions(), log: log)
      defer { without.close() }
      #expect(try !without.shows("Workspace files"))
    }

    @Test("A grant's role changes, and it can be removed")
    func grant() throws {
      let log = SheetLog()
      let screen = sheet(ShareViewState(grants: [ada]), actions(log), log: log)
      defer { screen.close() }
      #expect(try screen.shows("ada@example.com"))
      #expect(try !screen.shows("No grants yet."))
      // General access, then the grant's role, then the new grant's role.
      try screen.pick("Edit", in: screen.pickers[1])
      #expect(log.calls == ["role ada edit"])
      try screen.click(try #require(screen.plainButtons.first))
      #expect(log.calls == ["role ada edit", "remove ada"])
    }

    @Test("Without the action a grant can't be removed")
    func noRemove() throws {
      let log = SheetLog()
      var limited = actions(log)
      limited.removeGrant = nil
      let screen = sheet(ShareViewState(grants: [ada]), limited, log: log)
      defer { screen.close() }
      #expect(screen.plainButtons.isEmpty)
    }

    private func field(_ screen: OffscreenWindow<AnyView>) throws -> NSTextField {
      try #require(screen.allViews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    }

    @Test("Add invites the typed person with the chosen role, then clears the field")
    func add() throws {
      let log = SheetLog()
      let screen = sheet(ShareViewState(), actions(log), log: log)
      defer { screen.close() }
      let enabledBefore = screen.controlFrames.count
      let input = try field(screen)
      try screen.click(input)
      try screen.type("  bob@example.com ")
      // Add has come on.
      #expect(screen.controlFrames.count == enabledBefore + 1)
      try screen.pick("Edit", in: try #require(screen.pickers.last))
      // Add, then Done.
      try screen.clickControl(at: screen.controlFrames.count - 2)
      #expect(log.calls == ["add bob@example.com edit"])
      #expect(input.stringValue.isEmpty)
      #expect(screen.controlFrames.count == enabledBefore)
    }

    @Test("Return in the field adds too, but blank text adds nothing")
    func addWithReturn() throws {
      let log = SheetLog()
      let screen = sheet(ShareViewState(), actions(log), log: log)
      defer { screen.close() }
      try screen.click(try field(screen))
      try screen.type("   ")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(log.calls.isEmpty)
      try screen.type("bob")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(log.calls == ["add bob read"])
    }

    @Test("Without the action nothing can be added")
    func cantAdd() throws {
      let log = SheetLog()
      let screen = sheet(ShareViewState(), ShareActions(), log: log)
      defer { screen.close() }
      #expect(try field(screen).isEnabled == false)
    }

    @Test("An error shows")
    func error() throws {
      let log = SheetLog()
      let screen = sheet(ShareViewState(errorMessage: "Couldn't save"), actions(log), log: log)
      defer { screen.close() }
      #expect(try screen.shows("Couldn't save"))
    }

    @Test("Copy link copies the session's link and says so")
    func copyLink() throws {
      let log = SheetLog()
      let link = try #require(URL(string: "https://example.test/s"))
      let screen = sheet(ShareViewState(link: link), actions(log), log: log)
      defer { screen.close() }
      #expect(try screen.shows("Copy link"))
      #expect(try screen.shows("Share\u{2026}"))
      // Copy link, Share, Done.
      try screen.clickControl(at: screen.controlFrames.count - 3)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "https://example.test/s")
      #expect(try screen.shows("Copied!"))
    }
  }
#endif
