import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentRemoteBrowser

/// The fixture host other tests and the gallery lean on: what it records and how its history moves.
@MainActor
@Suite("Fixture remote browser driver")
struct FixtureDriverLogicTests {
  private func eventually(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<200 {
      if condition() { return true }
      try await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  private func attached() async throws -> (RemoteBrowserStore, FixtureRemoteBrowserDriver) {
    let host = FixtureRemoteBrowser(latency: .milliseconds(1))
    host.addTab(id: "t", url: "https://example.com/")
    let store = RemoteBrowserStore(sessionID: "s", tabID: "t")
    store.pasteboard = MemoryPasteboard()
    store.attach(using: host, mode: .control, hostID: nil)
    #expect(try await eventually { store.canSendInput })
    return (store, try #require(store.fixtureDriver))
  }

  @Test("Input reaches the log, and the cursor follows the pointer's region")
  func inputLog() async throws {
    let (store, driver) = try await attached()
    store.send(
      MouseInput(
        kind: .down, x: 10, y: 10, button: .left, clicks: 1, modifiers: 0, dx: 0, dy: 0))
    #expect(driver.inputLog.contains("mouse down 10,10"))
    #expect(try await eventually { store.snapshot.cursor.keyword == "pointer" })
    store.send(
      MouseInput(kind: .move, x: 700, y: 500, button: nil, clicks: 0, modifiers: 0, dx: 0, dy: 0))
    #expect(try await eventually { store.snapshot.cursor.keyword == "default" })
    store.send(
      KeyInput(
        kind: .char, macKeyCode: nil, hidUsage: nil, code: nil, key: "a", text: "a", modifiers: 0,
        repeat: false))
    store.send(ImeInput(op: .commit, text: "\u{1F600}", selection: nil, replacement: nil))
    store.send(
      TouchInput(kind: .start, id: 1, x: 5, y: 6, radius: nil, pressure: nil, modifiers: 0))
    #expect(driver.inputLog.suffix(3).first == "key char a")
    #expect(driver.inputLog.suffix(2).first == "ime commit \u{1F600}")
    #expect(driver.inputLog.last == "touch start 5,6")
    store.foreground()
    #expect(driver.inputLog.last == "foreground")
    driver.replyDialog(id: "d", accept: true, text: nil)
    #expect(driver.inputLog.last == "dialog d true")
    driver.updateSettings(
      update: RemoteBrowserSettingsUpdate(
        maxFps: nil, quality: nil, scale: nil, codec: nil, stats: nil))
    #expect(driver.inputLog.last == "settings")
    try driver.resize(viewport: RemoteViewport(width: 1, height: 2, dpr: .nan))
    #expect(driver.inputLog.last == "resize 1x2")
    store.detach()
  }

  @Test("History moves back and forward, and an empty end doesn't move")
  func history() async throws {
    let (store, _) = try await attached()
    store.navigate(.back)
    store.navigate(.forward)
    #expect(store.navigation.url == "https://example.com/")
    #expect(store.submitAddress("https://one.example/"))
    #expect(try await eventually { store.navigation.url == "https://one.example/" })
    #expect(store.navigation.canGoBack)
    store.navigate(.back)
    #expect(try await eventually { store.navigation.url == "https://example.com/" })
    #expect(store.navigation.canGoForward)
    store.navigate(.forward)
    #expect(try await eventually { store.navigation.url == "https://one.example/" })
    store.navigate(.reload)
    store.navigate(.stop)
    #expect(try await eventually { !store.navigation.loading })
    #expect(store.navigation.progress == 1)
    store.detach()
  }

  @Test("Copy and cut answer with a selection; a viewer's stills arrive")
  func editsAndStills() async throws {
    let (store, driver) = try await attached()
    let board = try #require(store.pasteboard as? MemoryPasteboard)
    store.copy()
    #expect(try await eventually { board.text == "fixture selection" })
    board.text = "typed"
    store.paste()
    #expect(driver.inputLog.last == "edit paste typed")
    store.requestStill(.thumbnail)
    #expect(try await eventually { store.still?.jpeg.isEmpty == false })
    store.setVisible(false)
    store.setVisible(true)
    #expect(driver.inputLog.last == "keyframe flush")
    store.releaseControl()
    #expect(try await eventually { !store.canSendInput })
    store.takeControl()
    #expect(try await eventually { store.canSendInput })
    store.detach()
    #expect(try await eventually { store.snapshot.connection == .stopped })
  }
}
