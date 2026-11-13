#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentBrowser

  /// Shows Clear Browsing Data as a tab does: in a sheet, which Cancel closes.
  private struct ClearDataSheetHost: View {
    let environment: BrowserEnvironment
    let profileID: UUID
    @State private var isOpen = true

    var body: some View {
      Text("Page")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isOpen) {
          BrowserClearDataView(environment: environment, profileID: profileID)
        }
    }
  }

  extension OffscreenWindow {
    /// The button of this title in the sheet that is up, or else in the window.
    fileprivate func titledButton(_ title: String) throws -> NSButton {
      let found = allViews.compactMap { $0 as? NSButton }.first { $0.title == title }
      guard let found else { throw OffscreenWindowError.notFound("the button \(title)") }
      return found
    }
  }

  /// Clear Browsing Data's time range and its Cancel.
  @MainActor
  @Suite("Clear Browsing Data, answered", .serialized)
  struct ClearDataAnswerTests {
    /// A profile's history with a visit two hours old and one made now.
    private func seededHistory(_ fixture: TabFixture) throws -> BrowserHistoryStore {
      let history = fixture.environment.history(for: fixture.model.profileID)
      history.recordVisit(
        url: try testURL("https://old.example/"), title: "Old",
        at: Date().addingTimeInterval(-7_200))
      history.recordVisit(url: try testURL("https://new.example/"), title: "New")
      return history
    }

    @Test("choosing Last hour clears the last hour's history and keeps what is older")
    func lastHour() async throws {
      let fixture = try TabFixture()
      let history = try seededHistory(fixture)
      let screen = OffscreenWindow(
        BrowserClearDataView(
          environment: fixture.environment, profileID: fixture.model.profileID), width: 460,
        height: 420)
      defer { screen.close() }
      await screen.catchUp()
      let range = try #require(screen.allViews.compactMap { $0 as? NSPopUpButton }.first)
      #expect(range.titleOfSelectedItem == "All time")
      let frame = range.convert(range.bounds, to: screen.host)
      let menu = try screen.openMenu(CGPoint(x: frame.midX, y: frame.midY))
      #expect(
        menu.items.map(\.title) == ["Last hour", "Last 24 hours", "Last 7 days", "All time"])
      try screen.choose("Last hour", in: menu)
      await screen.catchUp()
      #expect(range.titleOfSelectedItem == "Last hour")
      // The picker, six toggles, Cancel, then Clear Data.
      try screen.clickControl(at: 8)
      await screen.letSheetSettle()
      #expect(history.visits.contains { $0.title == "Old" })
      #expect(!history.visits.contains { $0.title == "New" })
    }

    @Test("Cancel closes the sheet and clears nothing")
    func cancel() async throws {
      let fixture = try TabFixture()
      let history = try seededHistory(fixture)
      let screen = OffscreenWindow(
        ClearDataSheetHost(environment: fixture.environment, profileID: fixture.model.profileID),
        width: 520, height: 480)
      defer { screen.close() }
      await screen.letSheetSettle()
      try #require(screen.hasSheet)
      #expect(try screen.shows("Clear Browsing Data"))
      // The picker, six toggles, then Cancel.
      try screen.clickControl(at: 7)
      await screen.letSheetSettle()
      #expect(!screen.hasSheet)
      #expect(history.visits.contains { $0.title == "Old" })
      #expect(history.visits.contains { $0.title == "New" })
      #expect(fixture.provider.engines[.system]?.removed.isEmpty ?? true)
    }
  }

  /// The bookmark manager's Rename, as a real alert with its field and buttons.
  @MainActor
  @Suite("Bookmark Rename, answered", .serialized)
  struct BookmarkRenameAnswerTests {
    private typealias Screen = OffscreenWindow<BrowserBookmarksManagerView>

    /// The manager with one bookmark, "Alpha", and Rename chosen from its row's menu.
    private func renaming(_ store: BrowserBookmarkStore) async throws -> Screen {
      SystemSideEffects.install()
      SystemSideEffects.reset()
      SystemSideEffects.showAlertSheets()
      try store.add(url: try testURL("https://a.example/"), title: "Alpha")
      let screen = OffscreenWindow(
        BrowserBookmarksManagerView(store: store, open: { _, _ in }), width: 600, height: 480)
      await screen.catchUp()
      let row = try #require(screen.rowPoints.dropFirst().first)
      let menu = try #require(try screen.rowMenu(at: row))
      try screen.choose("Rename\u{2026}", in: menu)
      await screen.letSheetSettle()
      return screen
    }

    /// Types `title` over the alert's field.
    private func type(_ title: String, in screen: Screen) throws {
      let field = try #require(screen.fields.first)
      #expect(field.stringValue == "Alpha")
      try screen.click(field)
      screen.selectFieldText()
      try screen.type(title)
    }

    @Test("Save gives the bookmark the title typed over the old one")
    func save() async throws {
      let store = BrowserBookmarkStore(fileURL: nil)
      let screen = try await renaming(store)
      defer {
        screen.close()
        SystemSideEffects.reset()
      }
      try #require(screen.hasSheet, "Rename opens as an alert sheet")
      try type("Beta", in: screen)
      await screen.catchUp()
      try screen.click(try screen.titledButton("Save"))
      await screen.letSheetSettle()
      #expect(!screen.hasSheet)
      #expect(store.bar.children?.first?.title == "Beta")
    }

    @Test("Cancel leaves the bookmark's title alone, whatever was typed")
    func cancel() async throws {
      let store = BrowserBookmarkStore(fileURL: nil)
      let screen = try await renaming(store)
      defer {
        screen.close()
        SystemSideEffects.reset()
      }
      try #require(screen.hasSheet, "Rename opens as an alert sheet")
      try type("Beta", in: screen)
      await screen.catchUp()
      try screen.click(try screen.titledButton("Cancel"))
      await screen.letSheetSettle()
      #expect(!screen.hasSheet)
      #expect(store.bar.children?.first?.title == "Alpha")
    }
  }

  /// The profile manager's editor and delete confirmation, cancelled.
  @MainActor
  @Suite("Profile sheets, cancelled", .serialized)
  struct ProfileCancelTests {
    @Test("the editor's Cancel closes it and keeps the profile's name, whatever was typed")
    func editorCancel() async throws {
      let fixture = try TabFixture()
      let store = fixture.environment.profiles
      let second = try store.create(name: "Second", color: .green, avatar: .initials)
      let screen = OffscreenWindow(
        BrowserProfileManagerView(environment: fixture.environment), width: 520, height: 420)
      defer { screen.close() }
      await screen.catchUp()
      // The second row's Edit, after the first row's Edit and Delete and its own Make Default.
      try screen.clickDrawnButton(at: 3)
      await screen.letSheetSettle()
      try #require(screen.hasSheet)
      try screen.focusField()
      screen.selectFieldText()
      try screen.type("Renamed")
      await screen.catchUp()
      // Cancel, then Save, end the editor.
      try screen.clickDrawnButton(at: screen.drawnButtons.count - 2)
      await screen.letSheetSettle()
      #expect(!screen.hasSheet)
      #expect(store.profile(id: second.id)?.name == "Second")
      #expect(store.profiles.count == 2)
    }

    @Test("Cancel in the delete confirmation keeps the profile and its data")
    func deleteCancel() async throws {
      let fixture = try TabFixture()
      let store = fixture.environment.profiles
      let second = try store.create(name: "Second", color: .green, avatar: .initials)
      let screen = OffscreenWindow(
        BrowserProfileManagerView(environment: fixture.environment), width: 520, height: 420)
      defer { screen.close() }
      await screen.catchUp()
      SystemSideEffects.reset()
      // The confirmation's second button is Cancel.
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      try screen.clickDrawnButton(at: 4)
      await screen.letSheetSettle()
      #expect(SystemSideEffects.record.alertMessages == ["Delete Second?"])
      #expect(store.profile(id: second.id)?.name == "Second")
      #expect(fixture.provider.engines[.system]?.deleted.isEmpty ?? true)
      // Cancelled, the question is asked afresh the next time.
      try screen.clickDrawnButton(at: 4)
      await screen.letSheetSettle()
      #expect(SystemSideEffects.record.alertMessages == ["Delete Second?", "Delete Second?"])
      #expect(store.profiles.count == 2)
    }
  }
#endif
