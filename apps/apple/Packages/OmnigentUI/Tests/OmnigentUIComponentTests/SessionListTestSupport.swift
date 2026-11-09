#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The list, its rows and the hover a real pointer causes, on top of `OffscreenWindow`.
  extension OffscreenWindow {
    /// The first list in the window.
    var list: NSTableView? { allViews.lazy.compactMap { $0 as? NSTableView }.first }

    /// The AppKit-backed borderless buttons, in tree order.
    var plainButtons: [NSButton] {
      allViews.compactMap { view in
        String(describing: Swift.type(of: view)) == "SwiftUIAppKitButton" ? view as? NSButton : nil
      }
    }

    /// The `Menu`s, in tree order.
    var popUps: [NSButton] {
      allViews.compactMap { view in
        String(describing: Swift.type(of: view)) == "SwiftUIPopupButton" ? view as? NSButton : nil
      }
    }

    /// The buttons that collapse and expand a list's sections, top to bottom.
    var sectionToggles: [NSButton] {
      allViews.compactMap { $0 as? NSButton }
        .filter { Swift.type(of: $0) == NSButton.self && $0.accessibilityLabel() != nil }
    }

    /// Disclosure triangles of the list's outline rows, top to bottom.
    var disclosures: [NSButton] {
      allViews.compactMap { $0 as? NSButton }
        .filter { Swift.type(of: $0) == NSButton.self && $0.accessibilityLabel() == nil }
    }

    /// A list row's middle, from the top left of the view.
    func center(ofRow row: Int) throws -> CGPoint {
      let list = try #require(list)
      let frame = list.convert(list.rect(ofRow: row), to: activeWindow.contentView)
      return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Clicks a list row with the real mouse path. Rows without a drag or button in them need
    /// ``selectRow(_:)``: AppKit's click recognizer doesn't run for synthesized events.
    func clickRow(_ row: Int, modifiers: NSEvent.ModifierFlags = []) throws {
      try click(center(ofRow: row), modifiers: modifiers)
    }

    /// Selects a row as the list's own click handling does.
    func selectRow(_ row: Int) throws {
      try #require(list).selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      settle()
    }

    /// The context menu of a list row, with its actions wired as a right click wires them.
    func menu(ofRow row: Int) throws -> NSMenu? {
      try contextMenu(at: center(ofRow: row))
    }

    /// Opens the `Menu` that is this control in `controlFrames`, and returns its items.
    func openMenu(control index: Int) throws -> NSMenu {
      let frame = try #require(controlFrames.indices.contains(index) ? controlFrames[index] : nil)
      return try openMenu(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Opens a `Menu`, and returns its items.
    func openMenu(_ popUp: NSView) throws -> NSMenu {
      let frame = popUp.convert(popUp.bounds, to: activeWindow.contentView)
      return try openMenu(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Hovers a list row: it hosts its content in its own hosting view, which tracks by itself.
    func hoverRow(_ row: Int) throws {
      let point = try center(ofRow: row)
      let event = try #require(
        NSEvent.mouseEvent(
          with: .mouseMoved, location: host.convert(point, to: nil), modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
      let targets = allViews.filter { view in
        String(describing: Swift.type(of: view)).contains("HostingView")
          && view.convert(view.bounds, to: host).contains(point)
      }
      for target in targets {
        target.mouseEntered(with: event)
        target.mouseMoved(with: event)
      }
      settle()
    }

    /// Ends a hover over a list row.
    func endRowHover() throws {
      let event = try #require(
        NSEvent.mouseEvent(
          with: .mouseMoved, location: .zero, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
      for target in allViews
      where String(describing: Swift.type(of: target)).contains("HostingView") {
        target.mouseExited(with: event)
      }
      settle()
    }

    /// The borderless buttons in a list row.
    func plainButtons(inRow row: Int) throws -> [NSButton] {
      let list = try #require(list)
      return plainButtons.filter { button in
        let frame = button.convert(button.bounds, to: list)
        return list.row(at: CGPoint(x: frame.midX, y: frame.midY)) == row
      }
    }

    /// The `Menu`s in a list row.
    func popUps(inRow row: Int) throws -> [NSButton] {
      let list = try #require(list)
      return popUps.filter { button in
        let frame = button.convert(button.bounds, to: list)
        return list.row(at: CGPoint(x: frame.midX, y: frame.midY)) == row
      }
    }
  }

  extension NSMenu {
    /// Every item's title at this level, without separators.
    var titles: [String] { items.filter { !$0.isSeparatorItem }.map(\.title) }

    /// The item with this title, at any depth.
    func item(named title: String) -> NSMenuItem? {
      for item in items {
        if item.title == title { return item }
        if let found = item.submenu?.item(named: title) { return found }
      }
      return nil
    }
  }

  /// Records what the sidebar asks its host to do, and holds the state a host would.
  @MainActor
  @Observable
  final class SidebarSpy {
    var calls: [String] = []
    var selection: SidebarDestination?
    var search = ""
    var state: SidebarViewState

    init(_ state: SidebarViewState) {
      self.state = state
      // The sidebar keeps these across launches; each test starts from a fresh install.
      UserDefaults.standard.removeObject(forKey: SidebarNavigationOrder.collapsedSectionsKey)
      UserDefaults.standard.removeObject(forKey: SidebarNavigationOrder.expandedProjectsKey)
      SystemSideEffects.reset()
    }

    var sessionActions: SessionListActions {
      var actions = SessionListActions()
      actions.setPinned = { [self] in calls.append("pin \($0.id) \($1)") }
      actions.setArchived = { [self] in calls.append("archive \($0.id) \($1)") }
      actions.rename = { [self] in calls.append("rename \($0.id) \($1)") }
      actions.setUnread = { [self] in calls.append("unread \($0.id) \($1)") }
      actions.share = { [self] in calls.append("share \($0.id)") }
      actions.fork = { [self] in calls.append("fork \($0.id)") }
      actions.moveToProject = { [self] in calls.append("move \($0.id) \($1?.id ?? "none")") }
      actions.stop = { [self] in calls.append("stop \($0.id)") }
      actions.delete = { [self] in calls.append("delete \($0.id)") }
      actions.leave = { [self] in calls.append("leave \($0.id)") }
      actions.openInNewWindow = { [self] in calls.append("window \($0.id)") }
      actions.openInSplit = { [self] in calls.append("split \($0.id)") }
      actions.webURL = { URL(string: "https://example.test/s/\($0.id)") }
      actions.newSession = { [self] in calls.append("new session") }
      actions.retry = { [self] in calls.append("retry") }
      return actions
    }

    var actions: SidebarActions {
      var actions = SidebarActions(
        sessions: sessionActions, setDisplay: { [self] in calls.append("display \($0.show)") },
        setQuickFilter: { [self] in calls.append("filter \($0?.rawValue ?? "none")") },
        switchServer: { [self] in calls.append("server \($0.id)") },
        addServer: { [self] in calls.append("add server") },
        openServerSettings: { [self] in calls.append("server settings") },
        undo: { [self] in calls.append("undo \($0.id)") },
        dismissUndo: { [self] in calls.append("dismiss undo") },
        viewArchived: { [self] in calls.append("view archived") })
      actions.createProject = { [self] in calls.append("create \($0) \($1 ?? "-") \($2?.id ?? "-")")
      }
      actions.renameProject = { [self] in calls.append("rename project \($0.id) \($1) \($2 ?? "-")")
      }
      actions.deleteProject = { [self] in calls.append("delete project \($0.id)") }
      actions.setArchivedMany = { [self] in
        calls.append("archive many \($0.map(\.id).joined(separator: ",")) \($1)")
      }
      actions.dropSession = { [self] in calls.append("drop \($0.id) \($1)") }
      actions.reorderProjects = { [self] in
        calls.append("reorder \($0.map(\.id).joined(separator: ","))")
      }
      actions.newSessionInProject = { [self] in calls.append("new in \($0.id)") }
      actions.openProjectSettings = { [self] in calls.append("project settings \($0.id)") }
      actions.setProjectSort = { [self] in calls.append("project sort \($0)") }
      actions.signOut = { [self] in calls.append("sign out") }
      actions.loadMoreSessions = { [self] in calls.append("load more") }
      actions.loadProjectPage = { [self] in calls.append("load project \($0.id)") }
      return actions
    }
  }

  /// The real sidebar, bound to a spy as a host binds it.
  struct SidebarHarness: View {
    let spy: SidebarSpy
    var actions: SidebarActions?
    var isPeek = false

    var body: some View {
      SidebarView(
        state: spy.state, selection: Binding(get: { spy.selection }, set: { spy.selection = $0 }),
        searchText: Binding(get: { spy.search }, set: { spy.search = $0 }),
        actions: actions ?? spy.actions
      )
      .environment(\.isSidebarPeek, isPeek)
    }
  }

  /// Sessions most sidebar tests share. With every action set the rows are: 0 New session,
  /// 1 Inbox, 2 Canvas, 3 Running, 4 Needs you, then each section's header and rows.
  enum SidebarFixture {
    static let pinned = SessionSummary(id: "pinned", title: "Pinned one", isPinned: true)
    static let beta = SessionSummary(id: "beta", title: "Beta")
    static let gamma = SessionSummary(id: "gamma", title: "Gamma")

    /// Rows: 5 Pinned header, 6 pinned, 7 Projects header, 8 "No projects", 9 Sessions header,
    /// 10 beta, 11 gamma.
    static var state: SidebarViewState {
      SidebarViewState(list: SessionListViewState(sessions: [pinned, beta, gamma]))
    }
    static let pinnedRow = 6
    static let betaRow = 10
    static let gammaRow = 11
  }
#endif
