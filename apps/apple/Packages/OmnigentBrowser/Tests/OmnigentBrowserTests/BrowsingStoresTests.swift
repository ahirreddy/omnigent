import Foundation
import Testing

@testable import OmnigentBrowser

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appending(
    path: "OmnigentBrowserTests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@MainActor
@Suite("Profiles")
struct ProfileStoreTests {
  @Test func firstLaunchCreatesPersonalAndPersists() throws {
    let file = try temporaryDirectory().appending(path: "profiles.json")
    let store = BrowserProfileStore(fileURL: file)
    #expect(store.profiles.map(\.name) == ["Personal"])
    #expect(store.defaultProfileID == store.profiles[0].id)
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(BrowserProfileStore(fileURL: file).profiles == store.profiles)
  }

  @Test func createRenameRecolorDefaultAndReload() throws {
    let file = try temporaryDirectory().appending(path: "profiles.json")
    let store = BrowserProfileStore(fileURL: file)
    let work = try store.create(name: "  Work ", color: .orange, avatar: .symbol("briefcase.fill"))
    #expect(work.name == "Work")
    #expect(work.initials == "W")
    var renamed = work
    renamed.name = "Day Job"
    renamed.color = .teal
    renamed.avatar = .emoji("🛠")
    try store.update(renamed)
    try store.setDefault(work.id)
    let reloaded = BrowserProfileStore(fileURL: file)
    #expect(reloaded.profiles.map(\.name) == ["Personal", "Day Job"])
    #expect(reloaded.profile(id: work.id)?.color == .teal)
    #expect(reloaded.profile(id: work.id)?.avatar == .emoji("🛠"))
    #expect(reloaded.defaultProfileID == work.id)
  }

  @Test func storageIdentitiesAreIsolatedAndNeverAgentProfiles() throws {
    let store = BrowserProfileStore(fileURL: try temporaryDirectory().appending(path: "p.json"))
    let other = try store.create(name: "Other", color: .green)
    let first = store.profiles[0].browserProfile
    #expect(first != other.browserProfile)
    #expect(first.persistence == .persistent)
    #expect(first.storageKey != other.browserProfile.storageKey)
    #expect(first.dataStoreIdentifier != other.browserProfile.dataStoreIdentifier)
    #expect(BrowserUserProfile.isUserProfile(first))
    #expect(!BrowserUserProfile.isUserProfile(.ephemeral("agent:conversation")))
  }

  @Test func rejectsEmptyNamesAndDeletingTheLastProfile() async throws {
    let store = BrowserProfileStore(fileURL: try temporaryDirectory().appending(path: "p.json"))
    #expect(throws: BrowserError.self) { try store.create(name: "   ", color: .red) }
    await #expect(throws: BrowserError.self) { try await store.delete(id: store.profiles[0].id) }
    await #expect(throws: BrowserError.profileNotFound(UUID(uuid: UUID_NULL))) {
      try await store.delete(id: UUID(uuid: UUID_NULL))
    }
  }

  @Test func deletingTheDefaultPicksAnother() async throws {
    let store = BrowserProfileStore(fileURL: try temporaryDirectory().appending(path: "p.json"))
    let work = try store.create(name: "Work", color: .orange)
    try store.setDefault(work.id)
    try await store.delete(id: work.id)
    #expect(store.profiles.count == 1)
    #expect(store.defaultProfileID == store.profiles[0].id)
  }

  @Test func damagedFileIsMovedAsideAndReported() throws {
    let directory = try temporaryDirectory()
    let file = directory.appending(path: "profiles.json")
    try Data("{not json".utf8).write(to: file)
    let store = BrowserProfileStore(fileURL: file)
    #expect(store.lastError != nil)
    #expect(store.profiles.count == 1)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names.contains { $0.hasPrefix("profiles.json.damaged-") })
  }

  @Test func newerFileVersionIsRejected() throws {
    let file = try temporaryDirectory().appending(path: "v.json")
    try Data(#"{"version": 99, "value": [1]}"#.utf8).write(to: file)
    #expect(throws: BrowserError.restoreStateUnsupported(version: 99)) {
      _ = try BrowserPersistentFile<[Int]>(url: file, version: 1).load()
    }
  }
}

@MainActor
@Suite("History")
struct HistoryStoreTests {
  @Test func recordsDedupesAndSearches() throws {
    let store = BrowserHistoryStore(fileURL: nil)
    let now = Date()
    store.recordVisit(
      url: try testURL("https://swift.org/"), title: "Swift", at: now.addingTimeInterval(-600))
    store.recordVisit(
      url: try testURL("https://swift.org/"), title: "Swift", at: now.addingTimeInterval(-300))
    store.recordVisit(url: try testURL("https://example.com/swift"), title: "Example", at: now)
    store.recordVisit(
      url: try testURL("https://example.com/swift"), title: "Example 2",
      at: now.addingTimeInterval(5))
    store.recordVisit(url: try testURL("about:blank"), title: "", at: now)
    #expect(store.visits.count == 3)
    #expect(store.visits[0].title == "Example 2")
    let results = store.search("swi", now: now)
    #expect(results.first?.url == (try testURL("https://swift.org/")))
    #expect(results.count == 2)
    #expect(
      store.search("example swift", now: now).map(\.url) == [
        try testURL("https://example.com/swift")
      ])
    #expect(store.visits(matching: "EXAMPLE").count == 1)
  }

  @Test func persistsAndClearsByTime() throws {
    let file = try temporaryDirectory().appending(path: "history.json")
    let store = BrowserHistoryStore(fileURL: file)
    let old = Date().addingTimeInterval(-7_200)
    store.recordVisit(url: try testURL("https://old.example/"), title: "Old", at: old)
    store.recordVisit(url: try testURL("https://new.example/"), title: "New", typed: true)
    try store.flush()
    let reloaded = BrowserHistoryStore(fileURL: file)
    #expect(reloaded.visits.map(\.title) == ["New", "Old"])
    #expect(reloaded.visits[0].typed)
    reloaded.removeAll(since: Date().addingTimeInterval(-3_600))
    try reloaded.flush()
    #expect(BrowserHistoryStore(fileURL: file).visits.map(\.title) == ["Old"])
    #expect(reloaded.origins.map(\.absoluteString) == ["https://old.example"])
  }
}

@MainActor
@Suite("Bookmarks")
struct BookmarkStoreTests {
  @Test func toggleMoveRenameAndPersist() throws {
    let file = try temporaryDirectory().appending(path: "bookmarks.json")
    let store = BrowserBookmarkStore(fileURL: file)
    let url = try testURL("https://swift.org/")
    #expect(try store.toggle(url: url, title: "Swift"))
    #expect(store.isBookmarked(url))
    let folder = try store.addFolder(title: "Docs")
    let bookmark = try #require(store.bookmark(for: url))
    try store.move(id: bookmark.id, to: folder.id)
    try store.update(id: folder.id, title: "Reference")
    let reloaded = BrowserBookmarkStore(fileURL: file)
    #expect(reloaded.bar.children?.map(\.title) == ["Reference"])
    #expect(reloaded.bar.children?.first?.children?.map(\.url) == [url])
    #expect(reloaded.search("swift").count == 1)
    #expect(try !reloaded.toggle(url: url, title: "Swift"))
    #expect(!reloaded.isBookmarked(url))
    #expect(throws: BrowserError.self) { try reloaded.move(id: folder.id, to: folder.id) }
  }

  @Test func importsChromeAndSafariExports() throws {
    let chrome = """
      <!DOCTYPE NETSCAPE-Bookmark-file-1>
      <TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>
      <DL><p>
        <DT><H3 ADD_DATE="1" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
        <DL><p>
          <DT><A HREF="https://swift.org/" ADD_DATE="1">Swift &amp; Co</A>
          <DT><H3>News</H3>
          <DL><p>
            <DT><A HREF="https://news.example/">News</A>
          </DL><p>
        </DL><p>
        <DT><H3>Other</H3>
        <DL><p>
          <DT><A HREF="https://other.example/a?b=1&amp;c=2">Other page</A>
          <DT><A HREF="javascript:alert(1)">Bookmarklet</A>
        </DL><p>
      </DL><p>
      """
    let store = BrowserBookmarkStore(fileURL: nil)
    #expect(try store.importHTML(Data(chrome.utf8)) == 4)
    #expect(store.bar.children?.map(\.title) == ["Swift & Co", "News"])
    let imported = try #require(store.other.children?.first)
    #expect(imported.title == "Imported")
    #expect(imported.children?.first?.title == "Other")
    #expect(
      imported.children?.first?.children?.first?.url
        == (try testURL("https://other.example/a?b=1&c=2")))

    let safari = """
      <!DOCTYPE NETSCAPE-Bookmark-file-1>
      <HTML><HEAD><TITLE>Bookmarks</TITLE></HEAD><BODY><H1>Bookmarks</H1>
      <DT><H3 FOLDED>Favorites</H3><DL><p><DT><A HREF="https://apple.com/">Apple</A></DL><p>
      <DT><A HREF="https://webkit.org/">WebKit</A>
      </BODY></HTML>
      """
    let second = BrowserBookmarkStore(fileURL: nil)
    #expect(try second.importHTML(Data(safari.utf8)) == 2)
    #expect(second.bar.children?.map(\.title) == ["Apple"])
    #expect(throws: BrowserError.self) { try second.importHTML(Data("hello".utf8)) }
  }
}

@Suite("Omnibox")
struct OmniboxTests {
  static let cases: [(String, String?)] = [
    ("example.com", "https://example.com"),
    ("example.com/path?q=1", "https://example.com/path?q=1"),
    ("https://example.com/a b", "https://example.com/a%20b"),
    ("http://localhost:3000", "http://localhost:3000"),
    ("localhost", "http://localhost"),
    ("localhost:8080/api", "http://localhost:8080/api"),
    ("app.localhost", "http://app.localhost"),
    ("192.168.1.10", "http://192.168.1.10"),
    ("10.0.0.1:8443/x", "http://10.0.0.1:8443/x"),
    ("[::1]:8080", "http://[::1]:8080"),
    ("devbox:8080", "http://devbox:8080"),
    ("myapp.test", "http://myapp.test"),
    ("about:blank", "about:blank"),
    ("file:///tmp/a.html", "file:///tmp/a.html"),
    ("view-source:https://example.com", "view-source:https://example.com"),
    ("xn--bcher-kva.example", "https://xn--bcher-kva.example"),
    ("swift concurrency", nil),
    ("swift", nil),
    ("1.5", nil),
    ("what is 2+2?", nil),
    ("?example.com", nil),
    ("javascript:alert(1)", nil),
    ("user@example.com", nil),
    ("foo.b", nil),
  ]

  @Test(arguments: cases) func detectsURLsAndSearches(input: String, expected: String?) {
    #expect(BrowserOmnibox.likelyURL(input)?.absoluteString == expected)
  }

  @Test func searchesWithTheChosenEngine() throws {
    let input = BrowserOmnibox.interpret("swift & c++", searchEngine: .duckDuckGo)
    #expect(
      input
        == .search(
          query: "swift & c++", url: try testURL("https://duckduckgo.com/?q=swift%20%26%20c%2B%2B"))
    )
    #expect(
      BrowserOmnibox.interpret("?example.com", searchEngine: .google)?.url.host()
        == "www.google.com")
    #expect(BrowserOmnibox.interpret("   ", searchEngine: .google) == nil)
    #expect(BrowserSearchEngine.isValidTemplate("https://search.example/?q=%s"))
    #expect(!BrowserSearchEngine.isValidTemplate("https://search.example/?q="))
    #expect(!BrowserSearchEngine.isValidTemplate("ftp://x/%s"))
  }

  @MainActor @Test func suggestsTypedThenTabsBookmarksAndHistory() throws {
    let history = BrowserHistoryStore(fileURL: nil)
    history.recordVisit(url: try testURL("https://swift.org/documentation"), title: "Swift Docs")
    let bookmarks = BrowserBookmarkStore(fileURL: nil)
    try bookmarks.add(url: try testURL("https://swift.org/blog"), title: "Swift Blog")
    let tabID = UUID()
    let open = BrowserOmniboxOpenTab(
      id: tabID, profileID: UUID(), title: "Swift Forums",
      url: try testURL("https://forums.swift.org/"))
    let suggestions = BrowserOmnibox.suggestions(
      for: "swift", searchEngine: .google, history: history, bookmarks: bookmarks, openTabs: [open])
    #expect(suggestions.map(\.kind) == [.search, .openTab(tabID), .bookmark, .history])
  }
}
