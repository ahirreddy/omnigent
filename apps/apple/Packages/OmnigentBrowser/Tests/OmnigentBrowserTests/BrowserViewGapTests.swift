#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentBrowser

  /// A saved file that won't load, so its store starts with an error to show.
  private func damagedFile() throws -> URL {
    let url = try temporaryDirectory().appending(path: "damaged.json")
    try Data("{damaged".utf8).write(to: url)
    return url
  }

  @MainActor
  private final class OpenedPages {
    var pages: [(url: URL, newTab: Bool)] = []
    func open(_ url: URL, newTab: Bool) { pages.append((url, newTab)) }
  }

  @MainActor
  @Suite("Library views when things go wrong", .serialized)
  struct LibraryViewGapTests {
    @Test("double-clicking a visit opens it and closes the list")
    func historyDoubleClick() async throws {
      SystemSideEffects.install()
      let store = BrowserHistoryStore(fileURL: nil)
      let url = try testURL("https://a.example/")
      store.recordVisit(url: url, title: "Alpha")
      let opened = OpenedPages()
      let screen = OffscreenWindow(
        BrowserHistoryView(store: store, open: opened.open), width: 640, height: 480)
      defer { screen.close() }
      await screen.catchUp()
      // The row's content is only as wide as its text.
      let row = CGPoint(x: 60, y: try #require(screen.rowPoints.last).y)
      try screen.click(row, clickCount: 1)
      try screen.click(row, clickCount: 2)
      await screen.catchUp()
      #expect(opened.pages.first?.url == url)
      #expect(opened.pages.first?.newTab == false)
    }

    @Test("a history file that couldn't be read says so under the list")
    func historyError() async throws {
      SystemSideEffects.install()
      let store = BrowserHistoryStore(fileURL: try damagedFile())
      let screen = OffscreenWindow(
        BrowserHistoryView(store: store, open: { _, _ in }), width: 640, height: 480)
      defer { screen.close() }
      await screen.catchUp()
      let message = try #require(store.lastError?.localizedDescription)
      #expect(try screen.shows(message))
    }

    @Test("a bookmarks file that couldn't be read says so under the list")
    func bookmarksError() async throws {
      SystemSideEffects.install()
      let store = BrowserBookmarkStore(fileURL: try damagedFile())
      let screen = OffscreenWindow(
        BrowserBookmarksManagerView(store: store, open: { _, _ in }), width: 600, height: 480)
      defer { screen.close() }
      await screen.catchUp()
      let message = try #require(store.lastError?.localizedDescription)
      #expect(try screen.shows(message))
    }

    @Test("Rename asks for the new title and offers Save and Cancel")
    func bookmarkRename() async throws {
      SystemSideEffects.install()
      SystemSideEffects.reset()
      let store = BrowserBookmarkStore(fileURL: nil)
      try store.add(url: try testURL("https://a.example/"), title: "Alpha")
      let screen = OffscreenWindow(
        BrowserBookmarksManagerView(store: store, open: { _, _ in }), width: 600, height: 480)
      defer { screen.close() }
      await screen.catchUp()
      let row = try #require(screen.rowPoints.dropFirst().first)
      let menu = try #require(try screen.rowMenu(at: row))
      try screen.choose("Rename…", in: menu)
      await screen.letSheetSettle()
      #expect(SystemSideEffects.record.alertMessages == ["Rename"])
      #expect(store.bar.children?.first?.title == "Alpha")
    }
  }

  @MainActor
  @Suite("Profiles when the disk refuses", .serialized)
  struct ProfileViewGapTests {
    /// An environment whose profiles can't be saved; its folder's place is taken by a file.
    private func environment() throws -> BrowserEnvironment {
      let blocker = try temporaryDirectory().appending(path: "blocker")
      try Data("a file".utf8).write(to: blocker)
      return try makeEnvironment(directory: blocker.appending(path: "sub")).0
    }

    @Test("a profile that can't be saved shows why, in the manager")
    func saveFailure() async throws {
      let environment = try environment()
      let screen = OffscreenWindow(
        BrowserProfileManagerView(environment: environment), width: 520, height: 420)
      defer { screen.close() }
      await screen.catchUp()
      let message = try #require(environment.profiles.lastError?.localizedDescription)
      #expect(try screen.shows(message))

      let edit = try #require(screen.drawnButtons.first)
      try screen.click(CGPoint(x: edit.midX, y: edit.midY))
      await screen.letSheetSettle()
      #expect(screen.hasSheet)
      try screen.focusField()
      screen.selectFieldText()
      try screen.type("Renamed")
      await screen.catchUp()
      try screen.clickDrawnButton(at: screen.drawnButtons.count - 1)
      await screen.letSheetSettle()
      #expect(try screen.shows(message))
    }
  }

  @MainActor
  @Suite("Omnibox and tab content edges", .serialized)
  struct TabViewGapTests {
    private func content(_ fixture: TabFixture) -> OffscreenWindow<BrowserTabContentView> {
      OffscreenWindow(
        BrowserTabContentView(
          model: fixture.model, environment: fixture.environment, keyboardShortcuts: true),
        width: 900, height: 600)
    }

    /// The menu of the last row of the table in the sheet that's up.
    private func lastRowMenu(in screen: OffscreenWindow<BrowserTabContentView>) throws -> NSMenu? {
      let rows = screen.allViews.compactMap { $0 as? NSTableRowView }
      let row = try #require(rows.max { $0.frame.minY < $1.frame.minY })
      let table = try #require(screen.allViews.compactMap { $0 as? NSTableView }.first)
      let event = NSEvent.mouseEvent(
        with: .rightMouseDown, location: row.convert(NSPoint(x: 60, y: row.bounds.midY), to: nil),
        modifierFlags: [], timestamp: 0, windowNumber: table.window?.windowNumber ?? 0,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
      return try table.menu(for: #require(event))
    }

    @Test("History's rows open pages in this tab or a new one")
    func historySheetOpens() async throws {
      let fixture = try TabFixture()
      let url = try testURL("https://visited.example/")
      fixture.environment.history(for: fixture.model.profileID).recordVisit(url: url, title: "V")
      var newTabs: [BrowserTabModel] = []
      fixture.environment.onOpenTab = { model, _ in newTabs.append(model) }
      let screen = content(fixture)
      defer { screen.close() }
      await screen.catchUp()
      try screen.choose("History", in: screen.popupMenu())
      await screen.letSheetSettle()
      let menu = try #require(try lastRowMenu(in: screen))
      try screen.choose("Open in New Tab", in: menu)
      #expect(newTabs.first?.url == url)
      try screen.choose("Open", in: menu)
      await screen.catchUp()
      #expect(fixture.model.url == url)
    }

    @Test("submitting nothing explains itself and doesn't navigate")
    func emptySubmit() async throws {
      let fixture = try TabFixture()
      let screen = OffscreenWindow(
        BrowserOmniboxField(
          model: fixture.model, environment: fixture.environment, style: .toolbar
        ).frame(width: 600), width: 700, height: 400)
      defer { screen.close() }
      await screen.catchUp()
      try screen.focusField()
      screen.selectFieldText()
      try screen.press(keyCode: 51, characters: "\u{7f}")
      await screen.catchUp()
      try screen.pressReturn()
      await screen.catchUp()
      #expect(fixture.model.url?.absoluteString == "https://a.example/page")
    }

    @Test("Share is off for a page that can't be shared, and on for one that can")
    func shareButton() async throws {
      let fixture = try TabFixture(url: nil)
      let screen = OffscreenWindow(BrowserShareButton(model: fixture.model), width: 80, height: 40)
      defer { screen.close() }
      await screen.catchUp()
      #expect(screen.controlFrames.isEmpty)
      let page = try TabFixture()
      let shareable = OffscreenWindow(BrowserShareButton(model: page.model), width: 80, height: 40)
      defer { shareable.close() }
      await shareable.catchUp()
      #expect(!shareable.controlFrames.isEmpty)
    }

    @Test("the touch bar's address shows a prompt until there's a page")
    func domainLabel() async throws {
      SystemSideEffects.install()
      let empty = OffscreenWindow(BrowserDomainLabel(url: nil), width: 240, height: 40)
      defer { empty.close() }
      await empty.catchUp()
      #expect(try empty.shows("Search or enter website"))
    }

    @Test("a popup the engine can't open anymore is reported on the tab that asked")
    func blockedPopupFails() throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let failure = BrowserError.engineNotBundled(.system, reason: "gone")
      fixture.provider.failures[.system] = failure
      fixture.model.controller.openBlockedPopup(
        BrowserBlockedPopup(url: try testURL("https://pop.example/"), reason: "Blocked"))
      #expect(tab.state.lastError == failure)
      #expect(fixture.model.controller.availability(of: .system) == .unavailable(failure))
    }

    @Test("address text with no usable address is refused")
    func addressText() throws {
      #expect(throws: BrowserError.self) { try BrowserController.url(fromAddressText: "a b") }
      #expect(throws: BrowserError.self) { try BrowserController.url(fromAddressText: "http://[") }
      #expect(throws: Never.self) { try BrowserController.url(fromAddressText: "about:blank") }
    }

    @Test("a permission the browser doesn't know is refused without asking")
    func unknownPermission() throws {
      let fixture = try PresenterFixture()
      var answer: BrowserPermissionAnswer?
      fixture.presenter.tab(
        fixture.tab,
        didRequest: .permission(
          BrowserPermissionPrompt(origin: "https://a.example", permissions: .other) { answer = $0 }
        ))
      #expect(answer == .deny)
    }
  }
#endif
