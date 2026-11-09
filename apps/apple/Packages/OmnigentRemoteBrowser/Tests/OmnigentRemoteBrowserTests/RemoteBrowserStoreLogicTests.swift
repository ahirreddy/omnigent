import CoreGraphics
import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentRemoteBrowser

@MainActor
@Suite("Remote browser store")
struct RemoteBrowserStoreLogicTests {
  private let mouse = MouseInput(
    kind: .move, x: .nan, y: .infinity, button: nil, clicks: .max, modifiers: .max, dx: .nan,
    dy: -.infinity)
  private let key = KeyInput(
    kind: .char, macKeyCode: nil, hidUsage: nil, code: nil, key: "", text: nil, modifiers: 0,
    repeat: false)
  private let ime = ImeInput(op: .cancel, text: nil, selection: nil, replacement: nil)
  private let touch = TouchInput(
    kind: .cancel, id: .max, x: .nan, y: .nan, radius: nil, pressure: nil, modifiers: 0)

  private func eventually(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<200 {
      if condition() { return true }
      try await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  /// A store attached to a recording connector, its pasteboard kept off the system's.
  private func attached(lastURL: String = "") -> (RemoteBrowserStore, RecordingConnector) {
    let connector = RecordingConnector()
    let store = RemoteBrowserStore(sessionID: "s", tabID: "t", lastURL: lastURL)
    store.pasteboard = MemoryPasteboard()
    store.attach(using: connector, mode: .control, hostID: nil)
    return (store, connector)
  }

  private func snapshot(
    connection: RemoteBrowserConnection = .attached(mode: .control),
    holder: ControlHolder? = .this, url: String? = "https://example.com/", edit: Bool = false
  ) -> RemoteBrowserSnapshot {
    var snapshot = RemoteBrowserSnapshot.initial(url: "", profile: "work")
    snapshot.connection = connection
    snapshot.nav = url.map {
      RemoteBrowserNav(
        url: $0, title: "", loading: true, progress: 0.5, canGoBack: false, canGoForward: false,
        faviconUrl: nil)
    }
    snapshot.control = holder.map {
      RemoteBrowserControl(owner: .unknown(value: ""), holder: $0, userId: nil, handoff: nil)
    }
    snapshot.capabilities.edit = edit
    return snapshot
  }

  /// Gives `store` a snapshot through its listener and waits until it has applied it.
  private func send(
    _ state: RemoteBrowserSnapshot, to store: RemoteBrowserStore, via connector: RecordingConnector
  ) async throws {
    connector.listener?.onState(snapshot: state)
    #expect(try await eventually { store.snapshot == state })
  }

  @Test("Before the host reports, navigation shows the saved URL and profile")
  func beforeAttach() {
    let store = RemoteBrowserStore(
      sessionID: "", tabID: "", lastURL: "https://saved/", profile: "work")
    #expect(store.navigation.url == "https://saved/")
    #expect(store.profile == "work")
    #expect(!store.isEnded)
    #expect(!store.canSendInput)
    #expect(!store.canEdit)
    #expect(!store.showsOwnViewport)
    #expect(!store.submitAddress("https://example.com/"))
  }

  @Test("Every call before attaching or after detaching is ignored")
  func withoutADriver() throws {
    let store = RemoteBrowserStore(sessionID: "s", tabID: "t")
    store.pasteboard = MemoryPasteboard()
    store.detach()
    store.send(mouse)
    store.send(key)
    store.send(ime)
    store.send(touch)
    store.copy()
    store.selectAll()
    store.navigate(.reload)
    store.takeControl()
    store.releaseControl()
    store.setVisible(true)
    store.foreground()
    store.requestStill(.still)
    store.viewChanged(size: CGSize(width: CGFloat.nan, height: -1), scale: .nan)
    #expect(store.notice == nil)
    #expect(store.fixtureDriver == nil)
  }

  @Test("A snapshot with no nav or an empty URL keeps the last URL known")
  func keepsTheLastURL() async throws {
    let (store, connector) = attached(lastURL: "https://saved/")
    try await send(snapshot(url: nil), to: store, via: connector)
    #expect(store.lastURL == "https://saved/")
    #expect(store.navigation.url == "https://saved/")
    #expect(store.navigation.progress == 1)
    try await send(snapshot(url: ""), to: store, via: connector)
    #expect(store.navigation.url == "https://saved/")
    #expect(store.navigation.progress == 0.5)
    try await send(snapshot(url: "https://new/"), to: store, via: connector)
    #expect(store.lastURL == "https://new/")
    #expect(store.profile == "work")
    store.detach()
  }

  @Test("A progress that isn't a number passes through to the chrome")
  func nanProgress() async throws {
    let (store, connector) = attached()
    var state = snapshot(url: "https://nan/")
    state.nav?.progress = .nan
    connector.listener?.onState(snapshot: state)
    #expect(try await eventually { store.lastURL == "https://nan/" })
    #expect(store.navigation.progress.isNaN)
    store.detach()
  }

  @Test("Only an attached control session this client holds may send input")
  func whoMaySend() async throws {
    let (store, connector) = attached()
    let denied: [RemoteBrowserSnapshot] = [
      snapshot(holder: nil), snapshot(holder: .nobody), snapshot(holder: .other),
      snapshot(connection: .attached(mode: .view)), snapshot(connection: .connecting),
      snapshot(connection: .stopped),
    ]
    for state in denied {
      try await send(state, to: store, via: connector)
      #expect(!store.canSendInput)
      store.send(mouse)
      store.send(key)
      store.send(ime)
      store.send(touch)
      store.selectAll()
    }
    #expect(!connector.driver.log.contains("mouse"))
    #expect(!connector.driver.log.contains { $0.hasPrefix("edit") })

    try await send(snapshot(), to: store, via: connector)
    #expect(store.canSendInput)
    #expect(!store.canEdit)
    store.send(mouse)
    store.send(key)
    store.send(ime)
    store.send(touch)
    #expect(connector.driver.log.suffix(4) == ["mouse", "key", "ime", "touch"])
    try await send(snapshot(edit: true), to: store, via: connector)
    #expect(store.canEdit)
    store.detach()
  }

  @Test("A failure from the driver becomes a notice, with a remote error's own message")
  func driverFailures() async throws {
    let (store, connector) = attached()
    try await send(snapshot(), to: store, via: connector)
    connector.driver.fail(
      with: CoreError.RemoteBrowser(kind: .invalidUrl, message: "Bad URL", requiresSignIn: false))
    store.navigate(.back)
    #expect(store.notice == "Bad URL")
    connector.driver.fail(with: CoreError.InvalidState(message: "other"))
    store.send(mouse)
    #expect(store.notice?.contains("other") == true)
    connector.driver.fail(with: CancellationError())
    store.send(key)
    #expect(store.notice?.contains("CancellationError") == true)
    store.detach()
  }

  @Test("Host notices reach the user only when they are meant to")
  func hostNotices() async throws {
    let (store, connector) = attached()
    connector.listener?.onNotice(notice: RemoteBrowserNotice(message: "quiet", userFacing: false))
    connector.listener?.onNotice(notice: RemoteBrowserNotice(message: "", userFacing: true))
    connector.listener?.onNotice(notice: RemoteBrowserNotice(message: "loud", userFacing: true))
    #expect(try await eventually { store.notice == "loud" })
    store.detach()
  }

  @Test("Paste needs text; the page's copy lands on this store's pasteboard")
  func pasteboard() async throws {
    let (store, connector) = attached()
    let board = MemoryPasteboard()
    store.pasteboard = board
    try await send(snapshot(), to: store, via: connector)

    store.paste()
    #expect(store.notice == "The pasteboard has no text to paste.")
    board.text = ""
    store.paste()
    #expect(!connector.driver.log.contains { $0.hasPrefix("edit paste") })
    board.text = "hello"
    store.paste()
    #expect(connector.driver.log.last == "edit paste hello")
    store.copy()
    store.cut()
    #expect(connector.driver.log.suffix(2) == ["edit copy ", "edit cut "])

    let long = String(repeating: "\u{1F600}", count: 200_000)
    connector.listener?.onClipboard(op: .copy, text: long)
    #expect(try await eventually { board.text == long })
    connector.listener?.onClipboard(op: .cut, text: "")
    #expect(try await eventually { board.text?.isEmpty == true })
    store.detach()
  }

}

extension RemoteBrowserStoreLogicTests {
  @Test("Stills and closes are kept, unknown reasons included")
  func stillsAndCloses() async throws {
    let (store, connector) = attached()
    let empty = StillImage(kind: .thumbnail, ptsUs: .max, jpeg: Data())
    connector.listener?.onStill(still: empty)
    #expect(try await eventually { store.still == empty })
    connector.listener?.onClosed(reason: nil)
    connector.listener?.onClosed(reason: .unknown(value: ""))
    #expect(try await eventually { store.closedReason == .unknown(value: "") })
    connector.listener?.onClosed(reason: .crashed)
    #expect(try await eventually { store.closedReason == .crashed })
    store.detach()
  }

  @Test("Attaching twice keeps the first driver; detaching stops it")
  func lifecycle() {
    let (store, connector) = attached()
    store.attach(using: connector, mode: .view, hostID: "")
    #expect(connector.attachCount == 1)
    #expect(connector.driver.log.filter { $0 == "start" }.count == 1)
    store.takeControl()
    store.releaseControl()
    store.foreground()
    store.requestStill(.thumbnail)
    #expect(connector.driver.log.suffix(4) == ["take", "release", "foreground", "still thumbnail"])
    store.detach()
    #expect(connector.driver.log.last == "stop")
    store.takeControl()
    #expect(connector.driver.log.last == "stop")
  }

  @Test("Showing a tab asks for a keyframe; hiding it doesn't")
  func visibility() {
    let (store, connector) = attached()
    store.setVisible(false)
    #expect(connector.driver.log.last == "visible false")
    store.setVisible(true)
    #expect(connector.driver.log.suffix(2) == ["visible true", "keyframe flush"])
    store.detach()
  }

  @Test("A renderer asks for a keyframe when set, and through its own requests")
  func renderers() {
    let (store, connector) = attached()
    let renderer = RemoteVideoRenderer()
    store.renderer = renderer
    #expect(connector.driver.log.last == "keyframe flush")
    let count = connector.driver.log.count
    store.renderer = renderer
    #expect(connector.driver.log.count == count)
    renderer.requestKeyframe(.gap)
    #expect(connector.driver.log.last == "keyframe gap")
    store.renderer = nil
    store.detach()
    renderer.requestKeyframe(.user)
    #expect(!connector.driver.log.contains("keyframe user"))
  }

  @Test("Address text loads a URL or a search; blank or huge text doesn't trouble it")
  func addresses() {
    let (store, connector) = attached()
    #expect(!store.submitAddress(""))
    #expect(!store.submitAddress(" \n\t "))
    #expect(store.submitAddress("example.com"))
    #expect(connector.driver.log.last == "nav navigate https://example.com")
    #expect(store.submitAddress(String(repeating: "\u{1F600} ", count: 100_000)))
    #expect(store.submitAddress("\0"))
    store.navigate(.stop)
    #expect(connector.driver.log.last == "nav stop ")
    store.detach()
  }

  @Test("Zoom resets count; a remote error's message falls back to its description")
  func smallThings() {
    let store = RemoteBrowserStore(sessionID: "s", tabID: "t")
    store.resetZoom()
    store.resetZoom()
    #expect(store.zoomResets == 2)
    let remote = CoreError.RemoteBrowser(
      kind: .invalidUrl, message: "", requiresSignIn: true)
    #expect(remote.remoteBrowserMessage.isEmpty)
    #expect(CoreError.InvalidState(message: "x").remoteBrowserMessage.contains("x"))
  }
}
