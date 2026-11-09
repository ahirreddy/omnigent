#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// A host's folders in memory, and every read and choice the browser made.
  @MainActor
  final class FolderBrowserLog {
    var reads: [String?] = []
    var chosen: [String] = []
    var cancels = 0
    var listings: [String: FolderListing] = [:]
    var failures: [String: String] = [:]
    /// Reads waiting for a test to answer them, oldest first.
    var held: [CheckedContinuation<Void, Never>] = []
    var holdsReads = false

    func load(_ path: String?) async -> Result<FolderListing, FolderBrowseError> {
      reads.append(path)
      if holdsReads {
        await withCheckedContinuation { held.append($0) }
      }
      let key = path ?? "home"
      if let message = failures[key] { return .failure(FolderBrowseError(message: message)) }
      return .success(listings[key] ?? FolderListing(path: path, parent: nil, folders: []))
    }
  }

  /// The browser in a sheet, as the option chip and Switch Host present it.
  @Suite("New session: the folder browser", .serialized)
  @MainActor
  struct NewSessionFolderBrowserTests {
    private let log = FolderBrowserLog()

    private func open(initial: String? = nil) async -> OffscreenWindow<some View> {
      log.listings["home"] = FolderListing(
        path: "/home/me", parent: "/home",
        folders: [
          FolderListing.Entry(path: "/home/me/src", name: "src"),
          FolderListing.Entry(path: "/home/me/docs", name: "docs"),
        ])
      log.listings["/home"] = FolderListing(path: "/home", parent: "/", folders: [])
      log.listings["/home/me/src"] = FolderListing(
        path: "/home/me/src", parent: "/home/me", folders: [])
      let screen = OffscreenWindow(
        ComposerSheetHost(
          sheet: FolderBrowserView(
            initialPath: initial, load: log.load,
            choose: { log.chosen.append($0) }, cancel: { log.cancels += 1 })))
      screen.settle(0.5)
      await screen.drainTasks()
      return screen
    }

    @Test("It opens on the host's home, listing its folders")
    func opensHome() async throws {
      let screen = await open()
      defer { screen.close() }
      #expect(log.reads == [nil])
      #expect(try screen.shows("Choose a Folder"))
      #expect(try screen.shows("src"))
      #expect(try screen.shows("docs"))
      #expect(screen.fields.first?.stringValue == "/home/me")
      #expect(try screen.shows("/home/me"))
    }

    @Test("It opens on a given folder, with spaces around it ignored")
    func opensGiven() async throws {
      let screen = await open(initial: " /home/me/src ")
      defer { screen.close() }
      #expect(log.reads == ["/home/me/src"])
      #expect(try screen.shows("No Folders"))
    }

    @Test("An empty path reads as home")
    func emptyPath() async throws {
      let screen = await open(initial: "  ")
      defer { screen.close() }
      #expect(log.reads == [nil])
    }

    @Test("Choose takes the folder being shown when nothing is selected")
    func chooseShown() async throws {
      let screen = await open()
      defer { screen.close() }
      try screen.tapButton(fromEnd: 0)
      #expect(log.chosen == ["/home/me"])
    }

    private func rowPoint(_ screen: OffscreenWindow<some View>, row: Int) throws -> CGPoint {
      let table = try #require(screen.allViews.lazy.compactMap { $0 as? NSTableView }.first)
      let frame = table.convert(table.rect(ofRow: row), to: screen.activeWindow.contentView)
      // On the row's name.
      return CGPoint(x: frame.minX + 40, y: frame.midY)
    }

    @Test("Choose takes a selected row, and says which")
    func chooseSelected() async throws {
      let screen = await open()
      defer { screen.close() }
      try screen.click(try rowPoint(screen, row: 1))
      #expect(try screen.shows("/home/me/docs"))
      try screen.tapButton(fromEnd: 0)
      #expect(log.chosen == ["/home/me/docs"])
    }

    @Test("Return chooses and Escape cancels")
    func keyboard() async throws {
      let screen = await open()
      defer { screen.close() }
      // Off the path field, whose own Return reads the path instead.
      _ = screen.activeWindow.makeFirstResponder(nil)
      try screen.pressReturn()
      #expect(log.chosen == ["/home/me"])
      try screen.pressEscape()
      #expect(log.cancels == 1)
    }

    @Test("Cancel chooses nothing")
    func cancel() async throws {
      let screen = await open()
      defer { screen.close() }
      try screen.tapButton(fromEnd: 1)
      #expect(log.cancels == 1)
      #expect(log.chosen.isEmpty)
    }

    @Test("Double-clicking a row opens it")
    func doubleClick() async throws {
      let screen = await open()
      defer { screen.close() }
      try screen.click(try rowPoint(screen, row: 0), clickCount: 2)
      await screen.drainTasks()
      #expect(log.reads.last == "/home/me/src")
      #expect(screen.fields.first?.stringValue == "/home/me/src")
    }

    @Test("Up opens the enclosing folder, and isn't there at the top")
    func goUp() async throws {
      let screen = await open()
      defer { screen.close() }
      let atHome = screen.buttons.count
      // Past the sheet's title bar control.
      let upButton = try #require(screen.buttons.first { $0.minX > 20 && $0.minY > 40 })
      try screen.click(screen.clickPoint(upButton))
      await screen.drainTasks()
      #expect(log.reads.last == "/home")
      #expect(screen.buttons.count == atHome)
      log.listings["/"] = FolderListing(path: "/", parent: nil, folders: [])
      let again = try #require(screen.buttons.first { $0.minX > 20 && $0.minY > 40 })
      try screen.click(screen.clickPoint(again))
      await screen.drainTasks()
      #expect(log.reads.last == "/")
      #expect(screen.buttons.count == atHome - 1)
    }

    @Test("A typed absolute path opens with Go or Return; anything else has no Go")
    func typedPath() async throws {
      let screen = await open()
      defer { screen.close() }
      let field = try #require(screen.fields.first)
      try screen.type("x", intoField: 0)
      field.currentEditor()?.selectAll(nil)
      try screen.type("relative", intoField: 0)
      screen.settle(0.05)
      let withoutGo = screen.buttons.count
      field.currentEditor()?.selectAll(nil)
      try screen.type("/home", intoField: 0)
      screen.settle(0.05)
      #expect(screen.buttons.count == withoutGo + 1)
      // Go sits before Cancel and Choose.
      try screen.tapButton(fromEnd: 2)
      await screen.drainTasks()
      #expect(log.reads.last == "/home")

      field.currentEditor()?.selectAll(nil)
      try screen.type("/home/me/src", intoField: 0)
      try screen.press(keyCode: ComposerKey.returnKey, characters: "\r")
      await screen.drainTasks()
      #expect(log.reads.last == "/home/me/src")
    }

    @Test("A folder that can't be read says why; the listing and selection stay")
    func failure() async throws {
      log.failures["/home/me/src"] = "Permission denied"
      let screen = await open()
      defer { screen.close() }
      try screen.click(try rowPoint(screen, row: 0), clickCount: 2)
      await screen.drainTasks()
      #expect(try screen.shows("Cannot Read Folder"))
      #expect(try screen.shows("Permission denied"))
      #expect(screen.fields.first?.stringValue == "/home/me")
      try screen.tapButton(fromEnd: 0)
      #expect(log.chosen == ["/home/me/src"])
    }
  }
#endif
