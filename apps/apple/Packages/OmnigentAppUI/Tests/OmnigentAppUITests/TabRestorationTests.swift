import Foundation
import OmnigentCoreFFI
import OmnigentRemoteBrowser
import OmnigentTerminalStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// A remote browser whose tabs close badly, or don't open at all.
nonisolated private final class RefusingRemoteBrowser: RemoteBrowserConnecting, Sendable {
  struct Refused: Error {}
  private let base = FixtureRemoteBrowser(latency: .milliseconds(1))
  let refusesToOpen: Bool

  init(refusesToOpen: Bool = false) {
    self.refusesToOpen = refusesToOpen
  }

  func profiles(sessionID: String) async throws -> [RemoteBrowserProfile] {
    try await base.profiles(sessionID: sessionID)
  }

  func createTab(sessionID: String, url: String?, profile: String?) async throws
    -> RemoteBrowserTab
  {
    if refusesToOpen { throw Refused() }
    return try await base.createTab(sessionID: sessionID, url: url, profile: profile)
  }

  func closeTab(sessionID: String, tabID: String) throws { throw Refused() }

  func attach(
    sessionID: String, tabID: String, mode: RemoteBrowserMode, hostID: String?,
    listener: any RemoteBrowserListener
  ) -> any RemoteBrowserDriverProtocol {
    base.attach(sessionID: sessionID, tabID: tabID, mode: mode, hostID: hostID, listener: listener)
  }
}

/// Binding a window's tabs to its server: saving, closing pages and changing servers.
@MainActor
@Suite("Tab restoration", .serialized, .timeLimit(.minutes(1)))
struct TabRestorationTests {
  private func folder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  }

  private func remove(_ url: URL) {
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      // The test wrote nothing there.
      #expect((error as NSError).code == NSFileNoSuchFileError)
    }
  }

  private final class Restored {
    var pages: [SidebarDestination?] = []
  }

  private struct Bound {
    let session: ServerSession
    let browser: FakeBrowserHost
    let persistence: TabPersistence
    let context: TabWindowContext
    let screen: OffscreenWindow<AnyView>
    let restored: Restored
    let directory: URL
  }

  private func bound(remote: (any RemoteBrowserConnecting)? = nil) async throws -> Bound {
    SystemSideEffects.install()
    let connection = try await signedInStore(threeSessionServer())
    try await eventually("the session list") { connection.sessionList.isLoaded }
    let session = ServerSession(
      connection: connection, opener: ExternalURLOpener { _ in true }, remoteBrowser: remote)
    let directory = folder()
    let persistence = TabPersistence(directory: directory, debounce: .milliseconds(1))
    let browser = FakeBrowserHost()
    let context = TabWindowContext(persistence: persistence, browser: browser)
    let restored = Restored()
    let view = Color.clear.modifier(
      TabRestoration(session: session, context: context) { restored.pages.append($0) })
    let screen = OffscreenWindow(AnyView(view), width: 300, height: 200)
    try await settle(screen, until: "the binding") { !restored.pages.isEmpty }
    return Bound(
      session: session, browser: browser, persistence: persistence, context: context,
      screen: screen, restored: restored, directory: directory)
  }

  @Test("Closing a browser tab closes its page and keeps its final state to reopen it")
  func closingAPage() async throws {
    let bound = try await bound()
    defer {
      bound.screen.close()
      remove(bound.directory)
    }
    #expect(bound.browser.attached == [bound.context.window])
    let group = bound.session.tabs.group("conv_a")
    let id = UUID()
    let tab = group.open(.browser(browserID: id), browserState: Data("old".utf8))
    bound.browser.closeState = Data("final".utf8)
    group.close(tab.id)
    #expect(bound.browser.closed == [id])
    #expect(group.closed.last?.browserState == Data("final".utf8))
  }

  @Test("A page that can't give its state back still closes, and says its history was lost")
  func aPageThatFailsToClose() async throws {
    let bound = try await bound()
    defer {
      bound.screen.close()
      remove(bound.directory)
    }
    bound.browser.closeFails = true
    let group = bound.session.tabs.group("conv_a")
    let tab = group.open(.browser(browserID: UUID()), browserState: Data("old".utf8))
    group.close(tab.id)
    #expect(group.closed.last?.browserState == Data("old".utf8))
    #expect(bound.persistence.issue?.description.contains("history could not be kept") == true)
  }

  @Test("Saving reads fresh browser states; a page that won't encode says some tabs weren't saved")
  func saving() async throws {
    let bound = try await bound()
    defer {
      bound.screen.close()
      remove(bound.directory)
    }
    let group = bound.session.tabs.group("conv_a")
    let page = group.open(.browser(browserID: UUID()), browserState: Data("old".utf8))
    bound.browser.snapshotState = Data("fresh".utf8)
    let state = TabRestoration.groupState(
      "conv_a", of: bound.session.tabs, session: bound.session, browser: bound.browser)
    #expect(state?.snapshot.tabs.first { $0.id == page.id }?.browserState == Data("fresh".utf8))
    #expect(
      TabRestoration.groupState(
        "nobody", of: bound.session.tabs, session: bound.session, browser: bound.browser) == nil)

    bound.browser.snapshotFails = true
    let kept = TabRestoration.groupState(
      "conv_a", of: bound.session.tabs, session: bound.session, browser: bound.browser)
    #expect(kept?.snapshot.tabs.first { $0.id == page.id }?.browserState == Data("old".utf8))
    bound.persistence.flush()
    #expect(bound.persistence.issue?.description.contains("Some tabs could not be saved") == true)
  }

  @Test("Another server's sessions: the tabs leave with the old server")
  func anotherServer() async throws {
    let bound = try await bound()
    defer {
      bound.screen.close()
      remove(bound.directory)
    }
    bound.session.tabs.show(.session("conv_a"))
    #expect(!bound.session.tabs.groups.isEmpty)
    await bound.session.connection.connect(serverURL: "http://127.0.0.1:7777")
    try await settle(bound.screen, until: "the window to rebind") {
      bound.restored.pages.count == 2
    }
    #expect(bound.session.tabs.groups.isEmpty)
    #expect(bound.session.tabs.page == nil)
    #expect(bound.session.tabs.recentSessions.isEmpty)
  }

  @Test("A closing remote tab keeps its address; a close that fails is reported")
  func closingARemoteTab() async throws {
    let bound = try await bound(remote: RefusingRemoteBrowser())
    defer {
      bound.screen.close()
      remove(bound.directory)
    }
    let remote = try #require(bound.session.remoteBrowsers)
    let opened = try #require(
      await remote.open(sessionID: "conv_a", url: "https://example.com", profile: "work"))
    let group = bound.session.tabs.group("conv_a")
    let tab = group.open(
      .remoteBrowser(sessionID: "conv_a", tabID: opened.tab.id),
      browserState: try opened.record.encoded())
    _ = remote.store(sessionID: "conv_a", tabID: opened.tab.id, record: opened.record)

    let snapshot = try TabRestoration.snapshot(group, session: bound.session, browser: nil)
    let saved = try #require(snapshot.tabs.first { $0.id == tab.id })
    #expect(RemoteBrowserTabContainer.record(saved)?.profile == "work")

    let strip = TabAdapter.state(group, session: bound.session, browser: nil, issue: nil)
    #expect(strip.tabs.first { $0.id == tab.id }?.canDuplicate == false)

    group.close(tab.id)
    #expect(RemoteBrowserTabContainer.record(try #require(group.closed.last))?.profile == "work")
    try await eventually("the refusal") {
      bound.persistence.issue?.description.contains("could not be closed") == true
    }
  }

  @Test("A remote tab that can't open says so and adds nothing")
  func refusedRemoteTab() async throws {
    let connection = try await signedInStore(threeSessionServer())
    let session = ServerSession(
      connection: connection, remoteBrowser: RefusingRemoteBrowser(refusesToOpen: true))
    final class Failures { var messages: [String] = [] }
    let failures = Failures()
    let window = WindowTabs(
      session: session, context: TabWindowContext(), showAll: {},
      fail: { failures.messages.append($0) })
    await window.openRemoteBrowser(in: "conv_a", profile: "work", replacing: nil)
    #expect(failures.messages.count == 1)
    #expect(session.tabs.group("conv_a").tabs.count == 1, "only its chat")
  }
}
