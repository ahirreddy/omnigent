import AppKit
import Darwin
import Foundation
import OWLProtocol
import OmnigentViewTesting
import Testing

@testable import OmnigentWebLayer

@MainActor
@Suite("Session failures against a fake host", .serialized)
struct SessionFailureTests {
  private func reachReady(_ host: FakeHost, right: MachSendRight? = nil) throws {
    host.session.start()
    var hello = try host.hello(withPort: right == nil)
    if let right {
      hello = IncomingMessage(
        kindValue: hello.kindValue, request: 0, target: 0, protocolMajor: hello.protocolMajor,
        fields: hello.fields, port: right)
    }
    host.session.handle(hello)
    host.session.handle(try FakeHost.message(.ready))
  }

  @Test("a host that closes its channel but keeps running is ended and reported")
  func channelClosedButRunning() async throws {
    let host = try FakeHost(script: "exec /bin/sleep 20") {
      $0.pingInterval = .milliseconds(10)
      $0.hangTimeout = .seconds(30)
    }
    defer { host.cleanUp() }
    let (right, receive) = try FakeHost.sendRightWithReceive()
    try reachReady(host, right: right)
    #expect(host.session.isReady)
    let destroyed = mach_port_mod_refs(
      unsafe mach_task_self_, receive, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), -1)
    #expect(destroyed == KERN_SUCCESS)
    #expect(
      await host.eventually { if case .crashed = host.session.state { true } else { false } })
    #expect(host.session.state == .crashed(.channelFailed("The host closed its channel.")))
  }

  @Test("a host that signs on but never finishes starting Chromium times out")
  func readyTimesOut() async throws {
    let host = try FakeHost(script: "exec /bin/sleep 20") {
      $0.readyTimeout = .milliseconds(50)
    }
    defer { host.cleanUp() }
    host.session.start()
    host.session.handle(try host.hello())
    #expect(await host.eventually { host.session.state != .launching })
    guard case .failed(.hostTimedOut(let phase, _)) = host.session.state else {
      Issue.record("expected a timeout, got \(host.session.state)")
      return
    }
    #expect(phase == "starting Chromium")
  }

  @Test("a host that can't be executed fails the launch and says so")
  func notExecutable() throws {
    let host = try FakeHost(script: "exit 0")
    defer { host.cleanUp() }
    let executable = host.root
      .appending(path: "\(SessionConfiguration.hostAppName).app/Contents/MacOS")
      .appending(path: SessionConfiguration.hostAppName)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executable.path)
    host.session.start()
    guard case .failed = host.session.state else {
      Issue.record("expected a failed launch, got \(host.session.state)")
      return
    }
    #expect(host.session.process == nil)
  }

  @Test("a host that ignores Shutdown is killed, and open views wait for the next one")
  func shutdownKillsAStubbornHost() throws {
    let host = try FakeHost(script: "trap '' TERM; while :; do /bin/sleep 1; done")
    defer { host.cleanUp() }
    let view = host.session.profile(identifier: "a", persistence: .ephemeral).makeWebView()
    try reachReady(host)
    let process = try #require(host.session.process)
    host.session.shutdown()
    #expect(!process.isRunning)
    #expect(view.status == .waitingForHost)
  }

  @Test("quitting the app ends the host")
  func quitEndsTheHost() throws {
    let host = try FakeHost(script: "exec /bin/sleep 20")
    defer { host.cleanUp() }
    host.session.start()
    let process = try #require(host.session.process)
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    #expect(host.session.state == .stopped)
    #expect(!process.isRunning)
  }

  @Test("waiting for a host stops when the task is cancelled")
  func cancelledWait() async throws {
    let host = try FakeHost(script: "exec /bin/sleep 20")
    defer { host.cleanUp() }
    host.session.start()
    let waiting = Task { try await host.session.waitUntilReady(timeout: .seconds(30)) }
    waiting.cancel()
    await #expect(throws: WebLayerError.notReady) { try await waiting.value }
  }

  @Test("messages reach a real channel once the host is ready")
  func postsGoThroughTheChannel() throws {
    let host = try FakeHost(script: "exec /bin/sleep 20")
    defer { host.cleanUp() }
    try reachReady(host)
    let view = host.session.profile(identifier: "a", persistence: .ephemeral).makeWebView()
    #expect(view.lastError == nil)
    view.load(try #require(URL(string: "https://a.example/")))
    #expect(view.lastError == nil)
  }

  @Test("a Hello with a right the channel can't take aborts the launch")
  func secondHello() async throws {
    let host = try FakeHost(script: "exec /bin/sleep 20")
    defer { host.cleanUp() }
    host.session.start()
    // The first Hello's right is adopted; another one has nowhere to go.
    host.session.handle(try host.hello())
    host.session.handle(try host.hello())
    #expect(await host.eventually { host.session.state != .launching })
    guard case .failed(.channelFailed) = host.session.state else {
      Issue.record("expected a channel failure, got \(host.session.state)")
      return
    }
  }

  @Test("a host whose port stopped taking messages fails the handshake")
  func helloAckNotDelivered() async throws {
    let host = try FakeHost(script: "exec /bin/sleep 20")
    defer { host.cleanUp() }
    host.session.start()
    let hello = try host.hello(withPort: false)
    host.session.handle(
      IncomingMessage(
        kindValue: hello.kindValue, request: 0, target: 0, protocolMajor: hello.protocolMajor,
        fields: hello.fields, port: try FakeHost.fullPort()))
    #expect(await host.eventually { host.session.state != .launching })
    guard case .failed(.channelFailed) = host.session.state else {
      Issue.record("expected a channel failure, got \(host.session.state)")
      return
    }
  }

  @Test("a rejected Hello is still refused when the refusal can't be delivered")
  func rejectionNotDelivered() async throws {
    let host = try FakeHost(script: "exec /bin/sleep 20")
    defer { host.cleanUp() }
    host.session.start()
    let hello = try host.hello(major: 99, withPort: false)
    host.session.handle(
      IncomingMessage(
        kindValue: hello.kindValue, request: 0, target: 0, protocolMajor: hello.protocolMajor,
        fields: hello.fields, port: try FakeHost.fullPort()))
    #expect(await host.eventually { host.session.state != .launching })
    guard case .failed(.protocolMismatch) = host.session.state else {
      Issue.record("expected a mismatch, got \(host.session.state)")
      return
    }
  }

  @Test("a damaged list of profiles to delete doesn't stop the launch, and is recorded")
  func damagedPendingDeletions() throws {
    let host = try FakeHost(script: "exec /bin/sleep 20")
    defer { host.cleanUp() }
    try FileManager.default.createDirectory(
      at: host.session.pendingDeletionsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: host.session.pendingDeletionsURL)
    host.session.start()
    #expect(host.session.state == .launching)
    #expect(host.session.lastProtocolError != nil)
  }

  @Test("an exit report after a requested shutdown doesn't turn into a crash")
  func exitAfterShutdown() throws {
    let host = try FakeHost(script: "exec /bin/sleep 20")
    defer { host.cleanUp() }
    host.session.shutdown()
    host.session.hostExited(status: 0, signaled: false, generation: host.session.generation)
    #expect(host.session.state == .stopped)
    host.session.abortLaunch(.notReady)
    #expect(host.session.state == .failed(.notReady))
  }
}

@MainActor
@Suite("Views whose messages can't be sent", .serialized)
struct WebViewSendFailureTests {
  /// A view that believes it's live in a session that has no host.
  private func withoutAHost() -> ProtocolFixture {
    let fixture = ProtocolFixture()
    fixture.session.outgoingTap = nil
    return fixture
  }

  @Test("a command that can't be sent shows as the view's error")
  func commandFails() throws {
    let fixture = withoutAHost()
    fixture.webView.load(try #require(URL(string: "https://a.example/")))
    #expect(fixture.webView.lastError == .notReady)
  }

  @Test("loading a page sends it to a live host")
  func loadSends() throws {
    let fixture = ProtocolFixture()
    fixture.webView.load(try #require(URL(string: "https://a.example/")))
    #expect(fixture.last(.navigate)?.string(.URL) == "https://a.example/")
  }

  @Test("a view that can't be created is unavailable, with the reason")
  func creationFails() {
    let fixture = withoutAHost()
    fixture.webView.status = .waitingForHost
    fixture.webView.hostReady()
    #expect(fixture.webView.status == .unavailable(.notReady))
    #expect(fixture.webView.lastError == .notReady)
  }

  @Test("closing a view still closes it when the host can't be told")
  func closeFails() {
    let fixture = withoutAHost()
    fixture.webView.close()
    #expect(fixture.webView.status == .closed)
  }

  @Test("a profile that can't be created or destroyed says so, and doesn't crash")
  func profileFails() {
    let fixture = withoutAHost()
    let profile = fixture.session.profile(identifier: "new", persistence: .ephemeral)
    #expect(profile.lastError == .notReady)
    fixture.session.remove(profile)
    #expect(fixture.session.profile(identifier: "new", persistence: .ephemeral) !== profile)
  }

  @Test("a popup with no opener is closed, and a failed close is recorded")
  func orphanPopup() throws {
    let fixture = withoutAHost()
    try fixture.receive(.popupCreated, target: 999, WireEncoder().u64(.openerID, 123))
    #expect(fixture.session.lastProtocolError == .notReady)
  }

  @Test("the host stopping withdraws open prompts; a requested stop waits for the next host")
  func hostStopped() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(.permissionRequest, WireEncoder().u64(.promptID, 3))
    #expect(fixture.webView.pendingPrompts.count == 1)
    fixture.webView.hostBecameUnavailable(nil)
    #expect(fixture.webView.pendingPrompts.isEmpty)
    #expect(fixture.recorder.cancelled.map(\.1) == ["The Chromium web host stopped."])
    #expect(fixture.webView.status == .waitingForHost)
  }

  @Test("a permission prompt closed without a decision says so to the host")
  func permissionDismissed() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(.permissionRequest, WireEncoder().u64(.promptID, 3))
    guard case .permission(let request)? = fixture.recorder.requested.first else {
      Issue.record("no permission prompt")
      return
    }
    request.dismiss()
    let reply = try #require(fixture.last(.permissionReply))
    #expect(reply.u64(.permissionResult) == OWLPermissionResult.dismiss.rawValue)
  }

  @Test("proceeding past a certificate error the page allows tells the host")
  func certificateProceeds() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(
      .certificateError, WireEncoder().u64(.promptID, 1).bool(.overridable, true))
    guard case .certificateError(let certificate)? = fixture.recorder.requested.first else {
      Issue.record("no certificate prompt")
      return
    }
    certificate.proceed()
    #expect(fixture.last(.certificateReply)?.bool(.accepted) == true)
  }

  @Test("a link to another app with nobody to open it is reported")
  func externalURLWithNoDelegate() throws {
    let fixture = ProtocolFixture()
    fixture.webView.uiDelegate = nil
    var events: [WebViewEvent] = []
    fixture.webView.onEvent = { events.append($0) }
    try fixture.receive(.externalProtocol, WireEncoder().string(.URL, "zoommtg://join"))
    #expect(!events.isEmpty)
    #expect(fixture.webView.lastError != nil)
  }
}

@MainActor
@Suite("The page's context menu", .serialized)
struct WebContextMenuPresenterTests {
  private func contextMenu(_ fixture: ProtocolFixture) throws -> WebContextMenu {
    let params =
      #"{"linkURL":"","sourceURL":"","pageURL":"","frameURL":"","selectionText":"","isEditable":true}"#
    let items = #"""
      [{"id":7,"kind":"command","label":"Copy","enabled":true,"checked":false},
       {"id":0,"kind":"separator","label":"","enabled":false,"checked":false},
       {"id":0,"kind":"submenu","label":"More","enabled":true,"checked":false,
        "items":[{"id":8,"kind":"check","label":"Spell","enabled":false,"checked":true}]}]
      """#
    try fixture.receive(
      .contextMenu,
      WireEncoder().u64(.promptID, 1).double(.X, 4).double(.Y, 5).string(.menuItems, items).string(
        .menuParams, params))
    guard case .contextMenu(let menu)? = fixture.recorder.requested.last else {
      throw WebLayerError.invalidArgument("no context menu")
    }
    return menu
  }

  @Test("the app's items come first, then the host's, enabled and checked as sent")
  func items() throws {
    let fixture = ProtocolFixture()
    let menu = try contextMenu(fixture)
    let target = MenuTarget(menu: menu, appItems: [])
    let shown = WebContextMenuPresenter.makeMenu(
      menu, appItems: [WebAppMenuItem(title: "Save Page") {}], target: target)
    #expect(shown.items.map(\.title) == ["Save Page", "", "Copy", "", "More"])
    #expect(shown.items[2].isEnabled)
    let spell = try #require(shown.items[4].submenu?.items.first)
    #expect(spell.title == "Spell")
    #expect(!spell.isEnabled)
    #expect(spell.state == .on)
  }

  @Test("choosing a host item answers with its command")
  func hostItemChosen() throws {
    let fixture = ProtocolFixture()
    let menu = try contextMenu(fixture)
    let target = MenuTarget(menu: menu, appItems: [])
    let shown = WebContextMenuPresenter.makeMenu(menu, appItems: [], target: target)
    target.runHostItem(shown.items[0])
    target.finish(menuOpened: true)
    #expect(fixture.last(.contextMenuReply)?.i64(.commandID) == 7)
  }

  @Test("choosing an app item dismisses the host's menu, then runs the item")
  func appItemChosen() throws {
    let fixture = ProtocolFixture()
    let menu = try contextMenu(fixture)
    var ran = 0
    let appItems = [WebAppMenuItem(title: "Save Page") { ran += 1 }]
    let target = MenuTarget(menu: menu, appItems: appItems)
    let shown = WebContextMenuPresenter.makeMenu(menu, appItems: appItems, target: target)
    target.runAppItem(shown.items[0])
    target.finish(menuOpened: true)
    #expect(ran == 1)
    #expect(fixture.last(.contextMenuReply) != nil)
    #expect(menu.isFinished)
  }

  @Test("closing the menu without a choice dismisses it")
  func presentAndClose() throws {
    let fixture = ProtocolFixture()
    let menu = try contextMenu(fixture)
    let view = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    let window = Offscreen.window()
    window.contentView = view
    SystemSideEffects.reset()
    WebContextMenuPresenter.present(menu, in: view, appItems: [])
    #expect(SystemSideEffects.record.poppedUpMenuCount == 1)
    #expect(menu.isFinished)
    window.contentView = nil
  }
}
