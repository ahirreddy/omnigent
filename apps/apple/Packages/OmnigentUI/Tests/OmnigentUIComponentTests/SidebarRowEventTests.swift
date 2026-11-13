#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// What a pointer, the keyboard and VoiceOver do to the rows of the whole sidebar.
  @Suite("Sidebar: rows driven by events", .serialized)
  @MainActor
  struct SidebarRowEventTests {
    /// The title field of the row being renamed in place; the search field is not it.
    private func renameField(_ screen: OffscreenWindow<SidebarHarness>) -> NSTextField? {
      screen.allViews.compactMap { $0 as? NSTextField }
        .first { $0.isEditable && !($0 is NSSearchField) }
    }

    private func beginRename(_ screen: OffscreenWindow<SidebarHarness>) throws -> NSTextField {
      let point = try screen.center(ofRow: SidebarFixture.betaRow)
      try screen.click(point, clickCount: 1)
      try screen.click(point, clickCount: 2)
      screen.settle(0.2)
      let field = try #require(renameField(screen))
      try screen.click(field)
      return field
    }

    @Test("An in-place rename saves when a click on another row takes the focus from its field")
    func renameCommitsOnFocusLoss() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      let field = try beginRename(screen)
      field.currentEditor()?.moveToEndOfDocument(nil)
      try screen.type(" two")
      #expect(spy.calls.isEmpty, "nothing is saved while the field has the focus")
      try screen.clickRow(SidebarFixture.gammaRow)
      #expect(spy.calls == ["rename beta Beta two"])
      #expect(renameField(screen) == nil)
    }

    @Test("Escape in the in-place field abandons the rename")
    func renameCancelsOnEscape() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      _ = try beginRename(screen)
      try screen.type(" two")
      try screen.press(keyCode: 53, characters: "\u{1B}")
      #expect(renameField(screen) == nil)
      #expect(spy.calls.isEmpty)
    }

    @Test("VoiceOver's New session in project action on a folder starts a session there")
    func folderAccessibilityAction() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let home = GroupSortFixture.home
      let pages = ProjectFolderPages(
        visibleCount: 0, hasMore: false, isLoading: false, isLoaded: true, showMore: {}, load: nil)
      // The folder outside a list, where the accessibility tree reaches it.
      let folder = ProjectFolder(
        project: home, sessions: [], isExpanded: .constant(false), pages: pages,
        menu: ProjectMenu(
          project: home, projects: [home], sort: .recent, actions: spy.actions, rename: {},
          confirmDelete: {}),
        drop: { _ in false }, row: { _ in EmptyView() })
      let screen = OffscreenWindow(folder.frame(width: 280), width: 300, height: 80)
      defer { screen.close() }
      try screen.withAccessibilityTree {
        let element = try screen.accessibilityElement("sidebar-project-home")
        let action = try screen.customAction("New session in project", of: element)
        #expect(action.handler?() == true)
      }
      screen.settle()
      #expect(spy.calls == ["new in home"])
    }
  }
#endif
