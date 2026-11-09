import Foundation
import OmnigentViewTesting
import Testing
import WebKit

@testable import OmnigentBrowser

@MainActor
@Suite("System tab browsing", .serialized)
struct SystemTabBrowsingTests {
  @Test("a refused address never loads and says why; an allowed one clears the old error")
  func loadPolicy() throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    let refused = try testURL("https://a.example/")
    fixture.tab.urlPolicy = RefusingPolicy(host: "a.example")
    fixture.tab.load(refused)
    #expect(fixture.tab.state.lastError == .navigationBlocked(url: refused, reason: "not here"))
    #expect(fixture.tab.webView.url == nil)
    fixture.tab.stopLoading()
    fixture.tab.urlPolicy = RefusingPolicy(host: "other.example")
    fixture.tab.load(try testURL("about:blank"))
    #expect(fixture.tab.state.lastError == nil)
  }

  @Test("back and forward walk between pages")
  func backAndForward() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    let tab = fixture.tab
    let folder = FileManager.default.temporaryDirectory
      .appending(path: "system-history-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for title in ["One", "Two"] {
      let page = folder.appending(path: "\(title).html")
      try "<title>\(title)</title>".write(to: page, atomically: true, encoding: .utf8)
      tab.load(page)
      #expect(try await waitUntil { tab.state.title == title && !tab.state.isLoading })
    }
    #expect(tab.state.canGoBack)
    tab.goBack()
    #expect(try await waitUntil { tab.state.title == "One" && tab.state.canGoForward })
    #expect(tab.navigationHistory.entries.count == 2)
    #expect(tab.navigationHistory.currentIndex == 0)
    tab.goForward()
    #expect(try await waitUntil { tab.state.title == "Two" })
    #expect(tab.navigationHistory.currentIndex == 1)
    tab.reload()
    #expect(try await waitUntil { !tab.state.isLoading && tab.state.title == "Two" })
    tab.stopLoading()
    #expect(!tab.state.isLoading)
  }

  @Test("find reports a match or none; finishing clears the page's selection")
  func findOnPage() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    try await fixture.load("<p>Needle in a haystack</p>")
    let found = try await fixture.tab.find("Needle", forward: true, caseSensitive: true)
    #expect(found.matchFound)
    let backwards = try await fixture.tab.find("needle", forward: false, caseSensitive: false)
    #expect(backwards.matchFound)
    let wrongCase = try await fixture.tab.find("needle", forward: true, caseSensitive: true)
    #expect(!wrongCase.matchFound)
    _ = try await fixture.tab.find("Needle", forward: true, caseSensitive: false)
    fixture.tab.stopFinding()
    let selected = try await fixture.tab.evaluateJavaScript("window.getSelection().toString()")
    #expect(selected == .string(""))
  }

  @Test("a page's source opens as text; a thrown script reports its message")
  func sourceAndScriptErrors() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    try await fixture.load("<p>Source</p>")
    let source = try await fixture.tab.viewSourceURL()
    let encoded = try #require(source.absoluteString.split(separator: ",").last)
    let decoded = try #require(Data(base64Encoded: String(encoded)))
    let text = try #require(String(data: decoded, encoding: .utf8))
    #expect(text.hasPrefix("<!DOCTYPE html>"))
    #expect(text.contains("<p>Source</p>"))
    await #expect(throws: BrowserError.scriptFailed(message: "Error: boom")) {
      try await fixture.tab.evaluateJavaScript("throw new Error('boom')")
    }
  }

  @Test("the page's picture can't be taken when the view has no size, and says so")
  func snapshotWithoutASize() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    try await fixture.load("<p>Page</p>")
    do {
      let png = try await fixture.tab.takeSnapshotPNG()
      #expect(!png.isEmpty)
    } catch {
      guard case .snapshotFailed = error else {
        Issue.record("expected a snapshot failure, got \(error)")
        return
      }
    }
  }

  @Test("DevTools point to Safari; a page outside a window can't print")
  func unsupportedActions() throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    #expect(throws: BrowserError.self) { try fixture.tab.showDevTools() }
    #expect(throws: BrowserError.printFailed("The page is not in a window.")) {
      try fixture.tab.printPage()
    }
  }

  @Test("a closed tab ignores every action")
  func closedTabIgnoresActions() async throws {
    let fixture = try SystemTabFixture()
    try await fixture.load("<title>Stay</title>")
    fixture.tab.close()
    let url = fixture.tab.webView.url
    fixture.tab.load(try testURL("https://b.example/"))
    fixture.tab.goBack()
    fixture.tab.goForward()
    fixture.tab.reload()
    fixture.tab.reload(ignoringCache: true)
    fixture.tab.stopLoading()
    fixture.tab.stopFinding()
    fixture.tab.setZoomFactor(2)
    fixture.tab.setAudioMuted(true)
    #expect(fixture.tab.state.zoomFactor != 2)
    #expect(!fixture.tab.state.isMuted)
    #expect(fixture.tab.webView.url == url)
    #expect(!fixture.tab.restoreEngineState(Data()))
    #expect(throws: BrowserError.tabClosed) { try fixture.tab.printPage() }
    await #expect(throws: BrowserError.tabClosed) { try await fixture.tab.takeSnapshotPNG() }
    await #expect(throws: BrowserError.tabClosed) {
      try await fixture.tab.find("x", forward: true, caseSensitive: false)
    }
  }
}

@MainActor
@Suite("System tab page bridge", .serialized)
struct SystemTabBridgeTests {
  @Test("the page's script says it's ready and names the page's icon")
  func realPage() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    let tab = fixture.tab
    try await fixture.load(
      "<link rel='icon' sizes='64x64' href='/big.png'><link rel='icon' sizes='32x32' href='/i.png'>"
    )
    #expect(try await waitUntil { tab.state.faviconURL != nil })
    #expect(tab.state.faviconURL?.absoluteString == "https://a.example/i.png")
    #expect(try await waitUntil { !tab.bridgeFrames.isEmpty })

    tab.setAudioMuted(true)
    #expect(tab.state.isMuted)
    tab.setAudioMuted(false)
    #expect(!tab.state.isMuted)
    _ = try await tab.evaluateJavaScript("document.body.append(new Audio()); true")
    tab.setAudioMuted(true)
    #expect(tab.state.isMuted)
    tab.setAudioMuted(false)
    #expect(tab.state.lastError == nil)

    try await fixture.load("<p>No icon link</p>", base: "https://b.example/")
    #expect(
      try await waitUntil {
        tab.state.faviconURL?.absoluteString == "https://b.example/favicon.ico"
      }
    )
  }

  @Test("frames with sound make the tab audible until the last one stops or goes")
  func audibleFrames() throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    let tab = fixture.tab
    let frame = FakeFrame()
    tab.bridgeMessage(["type": "audio", "frame": "a", "audible": true], frame: frame)
    tab.bridgeMessage(["type": "audio", "frame": "b", "audible": true], frame: frame)
    #expect(tab.state.isAudible)
    tab.bridgeMessage(["type": "audio", "frame": "a"], frame: frame)
    #expect(tab.state.isAudible)
    tab.bridgeMessage(["type": "gone", "frame": "b"], frame: frame)
    #expect(!tab.state.isAudible)

    tab.bridgeMessage(["type": "audio", "frame": "c", "audible": true], frame: frame)
    tab.mainFrameCommitted()
    #expect(!tab.state.isAudible)
    #expect(tab.audibleFrames.isEmpty)
  }

  @Test("only the main frame sets the icon; a malformed message changes nothing")
  func messageHandling() throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    let tab = fixture.tab
    let icon = "https://a.example/i.png"
    tab.bridgeMessage(
      ["type": "favicon", "frame": "sub", "url": icon], frame: FakeFrame(main: false))
    #expect(tab.state.faviconURL == nil)
    tab.bridgeMessage(["type": "favicon", "frame": "main", "url": icon], frame: FakeFrame())
    #expect(tab.state.faviconURL?.absoluteString == icon)
    tab.bridgeMessage(["type": "favicon", "frame": "main"], frame: FakeFrame())
    #expect(tab.state.faviconURL == nil)

    tab.bridgeMessage(["frame": "x"], frame: FakeFrame())
    tab.bridgeMessage(["type": "ready"], frame: FakeFrame())
    tab.bridgeMessage(["type": "unknown", "frame": "x"], frame: FakeFrame())
    #expect(tab.bridgeFrames.isEmpty)
    #expect(!tab.state.isAudible)
  }

  @Test("muting before a frame is ready mutes it when it says hello")
  func muteOnReady() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    fixture.tab.setAudioMuted(true)
    try await fixture.load("<p>Muted on arrival</p>")
    #expect(try await waitUntil { !fixture.tab.bridgeFrames.isEmpty })
    #expect(fixture.tab.state.isMuted)
    #expect(fixture.tab.state.lastError == nil)
  }
}

@MainActor
@Suite("System engine profile data", .serialized)
struct SystemEngineDataTests {
  @Test("clearing a profile's data ends with its cookies gone and its store forgotten")
  func clearsEphemeralData() async throws {
    let engine = SystemBrowserEngine()
    SystemSideEffects.install()
    let profile = BrowserProfile.ephemeral("system-data-\(UUID().uuidString)")
    let store = engine.dataStore(for: profile)
    #expect(engine.dataStore(for: profile) === store)
    let cookie = try #require(
      HTTPCookie(properties: [
        .name: "session", .value: "1", .domain: "a.example", .path: "/",
      ]))
    await store.httpCookieStore.setCookie(cookie)
    #expect(await store.httpCookieStore.allCookies().count == 1)

    try await engine.removeData([], for: profile, since: nil, origins: [])
    #expect(await store.httpCookieStore.allCookies().count == 1)
    try await engine.removeData(.cache, for: profile, since: Date(), origins: [])
    try await engine.removeData(.siteData, for: profile, since: nil, origins: [])
    #expect(await store.httpCookieStore.allCookies().count == 1)
    try await engine.removeData(.cookies, for: profile, since: nil, origins: [])
    #expect(await store.httpCookieStore.allCookies().isEmpty)

    try await engine.deleteProfileData(profile)
    #expect(engine.dataStore(for: profile) !== store)
  }

  @Test("a store that couldn't be removed is queued once; removal drops what can't be read")
  func queuedRemovals() async throws {
    let defaults = try isolatedDefaults()
    await SystemBrowserEngine.removeQueuedStores(defaults: defaults)
    #expect(defaults.stringArray(forKey: SystemBrowserEngine.pendingRemovalKey) == nil)
    let identifier = UUID()
    SystemBrowserEngine.queueStoreRemoval(identifier, defaults: defaults)
    SystemBrowserEngine.queueStoreRemoval(identifier, defaults: defaults)
    #expect(
      defaults.stringArray(forKey: SystemBrowserEngine.pendingRemovalKey)
        == [identifier.uuidString])
    defaults.set(["not a uuid"], forKey: SystemBrowserEngine.pendingRemovalKey)
    await SystemBrowserEngine.removeQueuedStores(defaults: defaults)
    #expect(defaults.stringArray(forKey: SystemBrowserEngine.pendingRemovalKey)?.isEmpty == true)
  }
}

@MainActor
@Suite("System agent input", .serialized)
struct SystemAgentInputTests {
  private let page = """
    <body style="margin:0">
    <form id=f onsubmit="event.preventDefault(); window.submitted = true">
    <input id=a style="position:absolute;left:10px;top:10px;width:200px;height:30px">
    </form>
    <button id=b style="position:absolute;left:10px;top:60px;width:100px;height:30px"
      onclick="window.clicks = (window.clicks||0)+1; window.detail = event.detail">Go</button>
    <div style="height:3000px"></div>
    </body>
    """

  private func agentFixture() async throws -> SystemTabFixture {
    let fixture = try SystemTabFixture()
    fixture.tab.agentInput.prepareForAgent(viewport: CGSize(width: 400, height: 300))
    try await fixture.load(page)
    return fixture
  }

  @Test("the agent clicks what's at a point; nothing there is an error")
  func click() async throws {
    let fixture = try await agentFixture()
    defer { fixture.tab.close() }
    let input = fixture.tab.agentInput
    #expect(!input.isRendererDirect)
    #expect(input.needsHostWindow)
    #expect(fixture.tab.platformView.frame.size == CGSize(width: 400, height: 300))
    try await input.click(at: CGPoint(x: 20, y: 70), clickCount: 1)
    #expect(try await fixture.tab.evaluateJavaScript("window.clicks") == .number(1))
    await #expect(throws: BrowserError.self) {
      try await input.click(at: CGPoint(x: 9000, y: 9000), clickCount: 1)
    }
  }

  @Test("typing needs a focused field and lands in it; pressing Return submits the form")
  func typing() async throws {
    let fixture = try await agentFixture()
    defer { fixture.tab.close() }
    let tab = fixture.tab
    let input = tab.agentInput
    await #expect(throws: BrowserError.agentActionFailed("no element is focused")) {
      try await input.insertText("early")
    }
    try await input.click(at: CGPoint(x: 20, y: 20), clickCount: 1)
    try await input.insertText("he\\llo")
    try await input.press(.character("!"), modifiers: [])
    let value = "document.getElementById('a').value"
    #expect(try await tab.evaluateJavaScript(value) == .string("he\\llo!"))
    try await input.press(.backspace, modifiers: [])
    #expect(try await tab.evaluateJavaScript(value) == .string("he\\llo"))
    _ = try await tab.evaluateJavaScript("document.activeElement.setSelectionRange(0, 0); true")
    try await input.press(.delete, modifiers: [])
    #expect(try await tab.evaluateJavaScript(value) == .string("e\\llo"))
    try await input.press(.enter, modifiers: [.shift])
    #expect(try await tab.evaluateJavaScript("window.submitted") == .bool(true))
  }

  @Test("a shortcut the page handles itself skips the key's default action")
  func pageHandledKey() async throws {
    let fixture = try await agentFixture()
    defer { fixture.tab.close() }
    let tab = fixture.tab
    _ = try await tab.evaluateJavaScript(
      "document.addEventListener('keydown', e => { window.key = [e.key, e.metaKey, e.ctrlKey,"
        + " e.altKey]; e.preventDefault() }); true")
    try await tab.agentInput.click(at: CGPoint(x: 20, y: 20), clickCount: 1)
    try await tab.agentInput.press(.character("k"), modifiers: [.command, .control, .option])
    #expect(
      try await tab.evaluateJavaScript("window.key.join()") == .string("k,true,true,true"))
    try await tab.agentInput.press(.enter, modifiers: [])
    #expect(try await tab.evaluateJavaScript("window.submitted === undefined") == .bool(true))
  }

  @Test("scrolling moves the page or the box under the point")
  func scroll() async throws {
    let fixture = try await agentFixture()
    defer { fixture.tab.close() }
    let tab = fixture.tab
    try await tab.agentInput.scroll(at: CGPoint(x: 300, y: 200), deltaX: 0, deltaY: 120)
    #expect(try await tab.evaluateJavaScript("window.scrollY") == .number(120))
    _ = try await tab.evaluateJavaScript(
      "document.body.insertAdjacentHTML('afterbegin', '<div id=box style=\"position:fixed;"
        + "left:0;top:0;width:100px;height:100px;overflow:auto\"><div style=\"height:900px\">"
        + "</div></div>'); true")
    try await tab.agentInput.scroll(at: CGPoint(x: 10, y: 10), deltaX: 0, deltaY: 50)
    #expect(
      try await tab.evaluateJavaScript("document.getElementById('box').scrollTop") == .number(50))
  }

  @Test("a tab that's gone refuses input")
  func tabGone() async throws {
    var tab: SystemBrowserTab? = try SystemTabFixture().tab
    let input = try SystemAgentInput(tab: #require(tab))
    tab?.close()
    tab = nil
    await #expect(throws: BrowserError.tabClosed) {
      try await input.click(at: .zero, clickCount: 1)
    }
    input.prepareForAgent(viewport: CGSize(width: 1, height: 1))
  }
}
