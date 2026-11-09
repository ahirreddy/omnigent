import Foundation
import OmnigentViewTesting
import Testing

@testable import OmnigentBrowser

/// A file path nothing can be written to: its parent is a plain file.
private func unwritablePath() throws -> URL {
  let blocker = try temporaryDirectory().appending(path: "blocker")
  try Data("a file".utf8).write(to: blocker)
  return blocker.appending(path: "sub/store.json")
}

@MainActor
@Suite("Browser stores when the disk refuses", .serialized)
struct StoreFailureTests {
  @Test("a saved file that can't be read or written reports which file")
  func persistentFileErrors() throws {
    let folder = try temporaryDirectory().appending(path: "store.json")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let unreadable = BrowserPersistentFile<[String]>(url: folder, version: 1)
    #expect(throws: BrowserError.self) { try unreadable.load() }

    let unwritable = BrowserPersistentFile<[String]>(url: try unwritablePath(), version: 1)
    #expect(throws: BrowserError.self) { try unwritable.write(["value"]) }
  }

  @Test("a credential held in memory can be forgotten")
  func inMemoryCredentialRemoval() {
    let store = InMemoryBrowserCredentialStore()
    let space = BrowserProtectionSpace(
      host: "a.test", port: 443, realm: "Realm", scheme: "basic", isProxy: false, isSecure: true)
    store.save(BrowserCredential(username: "owl", password: "hoot"), for: space)
    #expect(store.credential(for: space)?.username == "owl")
    store.removeCredential(for: space)
    #expect(store.credential(for: space) == nil)
  }

  @Test("a debounced save that fails tells whoever is listening, and stays pending")
  func debouncedFailure() async throws {
    let file = BrowserPersistentFile<[String]>(
      url: try unwritablePath(), version: 1, debounce: .milliseconds(5))
    var reported: BrowserError?
    file.onError = { reported = $0 }
    #expect(!file.hasPendingWrite)
    try file.flush()
    file.schedule(["value"])
    #expect(file.hasPendingWrite)
    #expect(try await waitUntil { reported != nil })
    #expect(file.lastError == reported)
  }

  @Test("a damaged file that can't be moved aside is still reported")
  func damagedAndStuck() throws {
    let folder = try temporaryDirectory()
    let url = folder.appending(path: "store.json")
    try Data("{damaged".utf8).write(to: url)
    let manager = FileManager.default
    try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
    let file = BrowserPersistentFile<[String]>(url: url, version: 1)
    let (value, error) = file.loadMovingAsideIfDamaged()
    #expect(value == nil)
    #expect(error != nil)
    #expect(manager.fileExists(atPath: url.path))
  }

  @Test("a profile store that can't save says so; the next change tries again")
  func profileStoreSaveFailure() throws {
    let store = BrowserProfileStore(fileURL: try unwritablePath())
    #expect(store.lastError != nil)
    #expect(store.profiles.count == 1)
    #expect(throws: BrowserError.self) {
      try store.create(name: "Second", color: .green, avatar: .initials)
    }
    #expect(store.lastError != nil)
  }

  @Test("profiles can be found by engine profile, reordered, and an unknown one isn't saved")
  func profileLookupAndMove() throws {
    let store = BrowserProfileStore(fileURL: try temporaryDirectory().appending(path: "p.json"))
    let first = store.defaultProfile
    let second = try store.create(name: "Second", color: .green, avatar: .initials)
    let third = try store.create(name: "Third", color: .red, avatar: .initials)
    #expect(store.profile(for: second.browserProfile)?.id == second.id)
    #expect(store.profile(for: .ephemeral("nobody")) == nil)
    try store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
    #expect(store.profiles.map(\.id) == [third.id, first.id, second.id])
    try store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    #expect(store.profiles.map(\.id) == [first.id, second.id, third.id])
    let stranger = BrowserUserProfile(name: "Stranger", color: .blue)
    #expect(throws: BrowserError.profileNotFound(stranger.id)) { try store.update(stranger) }
  }

  @Test("bookmarks refuse impossible moves and removals, and report a failed save")
  func bookmarkRefusals() throws {
    let store = BrowserBookmarkStore(fileURL: nil)
    #expect(store.allFolders.count == 2)
    let folder = try store.addFolder(title: "Folder")
    let inner = try store.addFolder(title: "Inner", to: folder.id)
    #expect(store.allFolders.count == 4)
    #expect(throws: BrowserError.self) { try store.remove(id: store.bar.id) }
    #expect(throws: BrowserError.self) { try store.remove(id: store.other.id) }
    #expect(throws: BrowserError.self) { try store.move(id: UUID(), to: folder.id) }
    #expect(throws: BrowserError.self) { try store.move(id: folder.id, to: inner.id) }
    #expect(throws: BrowserError.self) { try store.move(id: folder.id, to: folder.id) }
    _ = try store.add(url: try testURL("https://a.example/"), title: "A")
    try store.removeAll()
    #expect(store.allBookmarks.isEmpty)
    #expect(store.allFolders.count == 2)

    let failing = BrowserBookmarkStore(fileURL: try unwritablePath())
    #expect(throws: BrowserError.self) {
      try failing.add(url: try testURL("https://a.example/"), title: "A")
    }
    #expect(failing.lastError != nil)
  }

  @Test("an imported file: a nested list with no heading, a link with no address, or no title")
  func bookmarkImportOddities() throws {
    let html = """
      <DL><p>
      <DT><A HREF="https://kept.example/">Kept</A>
      <DL><p><DT><A HREF="https://nested.example/">Nested</A></DL>
      <DT><A>No address</A>
      <DT><A HREF="no scheme">Not a URL</A>
      <DT><A HREF="https://untitled.example/"></A>
      <DT><H3>Unclosed</H3><DL><p><DT><A HREF="https://unclosed.example/">In unclosed</A>
      """
    let store = BrowserBookmarkStore(fileURL: nil)
    #expect(try store.importHTML(Data(html.utf8)) == 4)
    let titles = store.allBookmarks.map(\.title)
    #expect(titles.contains("Nested"))
    #expect(titles.contains("https://untitled.example/"))
    #expect(titles.contains("In unclosed"))
    #expect(!titles.contains("No address"))
    #expect(store.allFolders.map(\.title).contains("Unclosed"))
    #expect(BrowserBookmarkHTML.attribute("HREF", in: "NOPE=\"x\"") == nil)
  }

  @Test("a visit's title updates once the page reports it")
  func historyTitleUpdates() throws {
    let store = BrowserHistoryStore(fileURL: nil)
    let url = try testURL("https://a.example/")
    store.recordVisit(url: url, title: "")
    store.updateTitle("", for: url)
    store.updateTitle("Later", for: try testURL("https://other.example/"))
    #expect(store.visits.first?.title.isEmpty == true)
    store.updateTitle("Later", for: url)
    #expect(store.visits.first?.title == "Later")
    let entry = try #require(store.search("a.example").first)
    #expect(entry.title == "Later")
    #expect(entry.id == url)
  }

  @Test("closed tabs and a window's saved tabs are written when asked")
  func recentlyClosedFlush() throws {
    let url = try temporaryDirectory().appending(path: "closed.json")
    let store = BrowserRecentlyClosedStore(fileURL: url)
    let state = BrowserTabRestoreState(profileID: UUID(), url: try testURL("https://a.example/"))
    store.push(state)
    try store.flush()
    #expect(BrowserRecentlyClosedStore(fileURL: url).states.map(\.id) == [state.id])
    #expect(state.effectiveHistory.entries.map(\.url) == [state.url])
    let blank = BrowserTabRestoreState(profileID: UUID(), url: nil)
    #expect(blank.effectiveHistory == .empty)
    let session = BrowserSessionSnapshot(tabs: [state], selectedTabID: state.id)
    #expect(session.selectedTabID == state.id)
    #expect(session.tabs.count == 1)
  }

  @Test("a valid custom search address is used; an invalid one falls back")
  func customSearchEngine() throws {
    let settings = BrowserSettings(defaults: try isolatedDefaults())
    settings.searchEngineID = "custom"
    settings.customSearchTemplate = "not a template"
    #expect(settings.searchEngine.id == BrowserSearchEngine.google.id)
    settings.customSearchTemplate = "https://search.example/?q=%s"
    #expect(settings.searchEngine.id == "custom")
    #expect(settings.searchEngine.template == "https://search.example/?q=%s")
  }
}

/// A policy with nothing but rules.
private nonisolated struct RulesOnly: BrowserURLPolicy {
  var rules: BrowserURLRules { BrowserURLRules(deny: ["blocked.example"]) }
}

@MainActor
@Suite("Small browser values", .serialized)
struct BrowserValueGapTests {
  @Test("the engine provider always offers WebKit, once")
  func defaultProvider() throws {
    let provider = DefaultBrowserEngineProvider()
    #expect(provider.availability(of: .system) == .available)
    let first = try provider.engine(for: .system)
    let second = try provider.engine(for: .system)
    #expect(first === second)
    guard case .unavailable = provider.availability(of: .chromium) else {
      Issue.record("Chromium isn't offered without its factory")
      return
    }
    #expect(throws: BrowserError.self) { try provider.engine(for: .chromium) }
  }

  @Test("script results: invalid JSON is an error; numbers read back")
  func scriptValues() throws {
    #expect(throws: BrowserError.self) { try BrowserScriptValue(jsonData: Data("{".utf8)) }
    #expect(try BrowserScriptValue(jsonData: Data("3".utf8)).numberValue == 3)
    #expect(BrowserScriptValue.string("3").numberValue == nil)
  }

  @Test("the default URL policy follows its rules; a multicast address is private")
  func urlPolicyDefault() throws {
    #expect(RulesOnly().evaluate(try testURL("https://fine.example/")) == .allow)
    guard case .deny = RulesOnly().evaluate(try testURL("https://blocked.example/")) else {
      Issue.record("expected the rules to refuse it")
      return
    }
    let privateRules = BrowserURLRules(blockPrivateAddresses: true)
    for address in ["https://224.0.0.1/", "https://198.51.100.1/"] {
      guard case .deny = privateRules.evaluate(try testURL(address)) else {
        Issue.record("expected \(address) to be refused")
        return
      }
    }
  }

  @Test("the downloads list clears what's finished and knows what's still going")
  func downloadCenter() throws {
    let center = BrowserDownloadCenter()
    let running = BrowserDownload(
      url: nil, suggestedName: "a", destination: URL(filePath: "/tmp/a"), engine: .system,
      totalBytes: nil, cancel: {})
    let done = BrowserDownload(
      url: nil, suggestedName: "b", destination: URL(filePath: "/tmp/b"), engine: .system,
      totalBytes: nil, cancel: {})
    done.state = .complete
    center.add(running)
    center.add(done)
    #expect(center.hasActiveDownloads)
    center.clearFinished()
    #expect(center.items.map(\.id) == [running.id])
    running.state = .cancelled
    #expect(!center.hasActiveDownloads)
  }

  @Test("an app's context menu item keeps its title and action")
  func contextMenuItem() {
    var ran = false
    let item = BrowserContextMenuItem(title: "Open in App") { ran = true }
    #expect(item.title == "Open in App")
    item.action()
    #expect(ran)
  }

  @Test("the omnibox won't navigate to text that can't be an address")
  func omniboxRefusals() {
    #expect(BrowserOmnibox.likelyURL("https://a b\nc") == nil)
    #expect(BrowserOmnibox.likelyURL("http://") == nil)
    #expect(BrowserOmnibox.likelyURL("::::") == nil)
  }
}
