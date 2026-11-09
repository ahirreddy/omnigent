import Foundation
import OmnigentCoreFFI
import OmnigentDesktop
import OmnigentStores
import OmnigentTestSupport
import OmnigentViewTesting
import OmnigentViewTextReading
import OmnigentWorkspaceUI
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentUIComponents

/// The smaller pieces around a session: banners, workspace links and the menu bar's windows.
@MainActor
@Suite("Supporting screens", .serialized, .timeLimit(.minutes(1)))
struct SupportingScreensTests {
  @Test("A failed tab action shows its message, and Dismiss clears it")
  func tabFailureBanner() throws {
    final class Dismissed { var count = 0 }
    let dismissed = Dismissed()
    let screen = OffscreenWindow(
      TabFailureBanner(message: "The shell could not start") { dismissed.count += 1 }, width: 500,
      height: 80)
    defer { screen.close() }
    #expect(try screen.shows("The shell could not start"))
    try screen.clickControl(at: 0)
    #expect(dismissed.count == 1)
  }

  @Test("The updates link says it's reconnecting, in whole seconds of at least one")
  func linkStates() {
    let reason = CoreError.InvalidState(message: "lost it")
    #expect(ConnectionIssuesBanner.describe(.idle) == nil)
    #expect(ConnectionIssuesBanner.describe(.live) == nil)
    #expect(
      ConnectionIssuesBanner.describe(.reconnecting(reason: reason, failures: 1, delayMs: 1))
        == "Live updates reconnecting in 1s: lost it")
    #expect(
      ConnectionIssuesBanner.describe(.reconnecting(reason: reason, failures: 1, delayMs: 2_600))
        == "Live updates reconnecting in 3s: lost it")
    #expect(
      ConnectionIssuesBanner.describe(.failed(error: reason)) == "Live updates failed: lost it")
  }

  @Test("A cited file opens in the viewer; a cited folder shows in the Files tree")
  func links() async throws {
    let workspace = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
    MarkdownLinksAdapter.links(workspace).open(
      WorkspaceFileTarget(path: "README.md", line: 3, isFolder: false))
    try await eventually("the file") { workspace.document?.path == "README.md" }

    workspace.tab = .changes
    await MarkdownLinksAdapter.open(
      WorkspaceFileTarget(path: "Sources", line: nil, isFolder: true), in: workspace)
    #expect(workspace.tab == .files)
    #expect(workspace.document == nil)
    #expect(workspace.tree.selection == "Sources")
    #expect(workspace.tree.expanded.contains("Sources"))
  }

  @Test("A cited text file isn't an image")
  func citedImages() async throws {
    let workspace = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
    let links = MarkdownLinksAdapter.links(workspace)
    await #expect(throws: WorkspaceImageError.self) { try await links.image(at: "README.md") }
  }

  @Test("The agent picker's setting says to sign in, reads a catalog, and reports a failure")
  func pickerSource() async throws {
    let none = PickerVisibilityAdapter.source([])
    #expect(none.server.isEmpty)
    guard case .failed("Sign in to a server first.") = await none.load() else {
      Issue.record("no server asks to sign in")
      return
    }

    let connection = try await signedInStore(newSessionServer())
    guard case .loaded(let entries) = await PickerVisibilityAdapter.source([connection]).load()
    else {
      Issue.record("the catalog reads")
      return
    }
    #expect(entries.map(\.name).contains("Claude"))

    let failing = newSessionServer()
    failing.route("/v1/agents", .json(#"{"detail":"down"}"#, status: 500))
    let refused = try await signedInStore(failing)
    guard case .failed = await PickerVisibilityAdapter.source([refused]).load() else {
      Issue.record("the failure shows")
      return
    }
  }

  @Test("The menu bar lists a window's sessions while it's bound to a server and open")
  func menuBar() async throws {
    let connection = try await PreviewData.connectedDemoStore()
    try await eventually("the sessions") { connection.sessionList.sessionsByID.count == 3 }
    let menuBar = MenuBarSessions()
    let url = try #require(URL(string: "http://127.0.0.1:6767"))
    let instance = UUID()
    menuBar.register(connection, serverURL: url, instance: instance)
    let listed = menuBar.sessionsNeedingAttention.count
    #expect(listed > 0)
    menuBar.unregister(instance)
    #expect(menuBar.sessionsNeedingAttention.isEmpty)

    let screen = OffscreenWindow(
      Color.clear.menuBarSessions(connection, serverURL: url, instance: instance, in: menuBar),
      width: 200, height: 100)
    try await pause(screen)
    #expect(menuBar.sessionsNeedingAttention.count == listed)
    screen.host.rootView = Color.clear.menuBarSessions(
      connection, serverURL: nil, instance: instance, in: menuBar)
    try await settle(screen, until: "the server to go") {
      menuBar.sessionsNeedingAttention.isEmpty
    }
    screen.close()
  }
}
