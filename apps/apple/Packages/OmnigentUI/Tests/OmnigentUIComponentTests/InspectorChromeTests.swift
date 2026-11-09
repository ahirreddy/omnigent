#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Inspector: the right panel's chips and menus", .serialized)
  @MainActor
  struct InspectorChromeTests {
    @Test("A file chip shows that file, and its X closes it without showing it")
    func chips() throws {
      let host = WorkspaceHost()
      let screen = workspacePanel(host, slots: slotsWithDocuments)
      defer { screen.close() }
      try screen.clickControl(at: Chips.secondChip)
      #expect(host.calls == ["select two"])
      #expect(try screen.shows("viewer of two"))
      try screen.clickControl(at: Chips.firstClose)
      #expect(host.calls == ["select two", "close one"])
      #expect(host.selectedDocument == "two")
    }

    @Test("A file chip's context menu closes it")
    func chipMenu() throws {
      let host = WorkspaceHost()
      let screen = workspacePanel(host, slots: slotsWithDocuments)
      defer { screen.close() }
      let chip = screen.controlFrames[Chips.firstChip]
      let menu = try #require(try screen.contextMenu(at: CGPoint(x: chip.midX, y: chip.midY)))
      #expect(menu.titles == ["Close Tab"])
      try screen.choose("Close Tab", in: menu)
      #expect(host.calls == ["close one"])
    }

    @Test("No open files: no chips and no panel picker")
    func noDocuments() throws {
      let host = WorkspaceHost()
      let screen = workspacePanel(host)
      defer { screen.close() }
      #expect(screen.popUps.isEmpty)
      #expect(screen.controlFrames.count == 7)
    }

    @Test("Open new lists its sections and runs what's chosen; a disabled item can't be chosen")
    func openNew() throws {
      let host = WorkspaceHost()
      let screen = workspacePanel(
        host,
        slots: { host in
          var slots = WorkspaceSlots.filled
          slots.openNew = {
            [
              InspectorMenuSection(
                id: "open", title: "Heading",
                items: [
                  InspectorMenuItem(id: "terminal", title: "Terminal", systemImage: "terminal") {
                    host.calls.append("terminal")
                  },
                  InspectorMenuItem(
                    id: "browser", title: "Browser", systemImage: "safari", isEnabled: false
                  ) { host.calls.append("browser") },
                ]),
              InspectorMenuSection(
                id: "plain",
                items: [
                  InspectorMenuItem(id: "chat", title: "Side chat", systemImage: "bubble") {
                    host.calls.append("chat")
                  }
                ]),
            ]
          }
          return slots
        })
      defer { screen.close() }
      let popUp = try #require(screen.popUps.first)
      let menu = try screen.openMenu(popUp)
      #expect(menu.titles.contains("Heading"))
      #expect(menu.item(named: "Browser")?.isEnabled == false)
      #expect(menu.item(named: "Terminal")?.isEnabled == true)
      #expect(menu.item(named: "Side chat")?.isEnabled == true)
      try screen.choose("Terminal", in: menu)
      #expect(host.calls == ["terminal"])
    }

    @Test("An empty Open new list hides the menu")
    func openNewEmpty() throws {
      let host = WorkspaceHost()
      let screen = workspacePanel(
        host,
        slots: { _ in
          var slots = WorkspaceSlots.filled
          slots.openNew = { [] }
          return slots
        })
      defer { screen.close() }
      #expect(screen.popUps.isEmpty)
    }

    @Test("The panel picker lists tabs with counts and open files, and goes to the chosen one")
    func panelPicker() throws {
      let host = WorkspaceHost()
      let screen = workspacePanel(host, slots: slotsWithDocuments)
      defer { screen.close() }
      let menu = try screen.openMenu(#require(screen.popUps.first))
      #expect(menu.item(named: "Pull Requests") != nil)
      #expect(menu.item(named: "/repo/one.swift")?.state == .off)
      try screen.choose("/repo/two.swift", in: menu)
      #expect(host.calls == ["select two"])
      #expect(try screen.shows("viewer of two"))

      let reopened = try screen.openMenu(#require(screen.popUps.first))
      #expect(reopened.item(named: "/repo/two.swift")?.state == .on)
      try screen.choose("Agents", in: reopened)
      #expect(host.tab == .agents)
      #expect(host.selectedDocument == nil)
      #expect(try screen.shows("agents slot"))
    }

    @Test("The full screen button toggles and names what it will do next")
    func fullScreenButton() throws {
      let host = WorkspaceHost()
      let screen = workspacePanel(host)
      defer { screen.close() }
      #expect(try screen.shows("Full screen"))
      try screen.clickControl(at: Chips.fullScreenWithoutMenus)
      #expect(host.maximized)
      #expect(try screen.shows("Exit full screen"))
      try screen.clickControl(at: Chips.fullScreenWithoutMenus)
      #expect(!host.maximized)
    }

    @Test("A panel that can't fill the conversation has no full screen button")
    func noFullScreen() throws {
      let host = WorkspaceHost()
      let screen = OffscreenWindow(
        AnyView(
          WorkspacePanelHarness(
            host: host, state: .inspectorSample, slots: { _ in .filled }, hasMaximize: false)),
        width: 700, height: 500)
      defer { screen.close() }
      #expect(try !screen.shows("Full screen"))
      #expect(screen.controlFrames.count == 6)
    }
  }

  /// Positions in the panel's controls, after the six tabs.
  private enum Chips {
    static let fullScreenWithoutMenus = 6
    // Six tabs, the panel picker, full screen, then each file's chip and close button.
    static let firstChip = 8
    static let firstClose = 9
    static let secondChip = 10
  }
#endif
