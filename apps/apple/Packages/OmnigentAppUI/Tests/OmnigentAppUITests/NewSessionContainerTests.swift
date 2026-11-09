import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import OmnigentAppUI
@testable import OmnigentStores

/// The page's menus and sheets in its window, and what its controls do to the form.
@MainActor
@Suite("New session page wiring", .serialized, .timeLimit(.minutes(1)))
struct NewSessionContainerTests {
  private static let hostMenu = CGPoint(x: 124, y: 423)
  private static let agentMenu = CGPoint(x: 676, y: 423)

  /// The page in a window, its catalog read.
  private func page(
    _ server: AppServer, useThisMachine: UseThisMachineAction? = nil
  ) async throws -> OffscreenWindow<AnyView> {
    SystemSideEffects.install()
    SystemSideEffects.reset()
    let row = sessionRow("conv_a", host: "mac", workspace: "/work/recent", updatedAt: 5)
    server.route(
      "/v1/sessions", method: "GET", .json(#"{"object":"list","data":[\#(row)],"has_more":false}"#))
    let connection = try await signedInStore(server)
    try await eventually("the session list") { connection.sessionList.isLoaded }
    let container = NewSessionContainer(connection: connection, form: try isolatedForm()) { _ in }
    let screen = OffscreenWindow(
      AnyView(container.environment(\.useThisMachine, useThisMachine)), width: 900, height: 700)
    try await settle(screen, until: "the folder listing") {
      !server.requests("GET", "/v1/hosts/mac/filesystem").isEmpty
    }
    try await pause(screen, .milliseconds(150))
    return screen
  }

  /// The container's actions over a form and catalog already read.
  private func wired(_ server: AppServer = newSessionServer()) async throws -> WiredPage {
    let connection = try await signedInStore(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    let opened = OpenedSessions()
    let container = NewSessionContainer(connection: connection, form: form) {
      opened.ids.append($0)
    }
    return WiredPage(
      connection: connection, creation: creation, form: form, container: container, opened: opened)
  }

  @Test("A client core that didn't start says so instead of a blank page")
  func noCore() async throws {
    let connection = ConnectionStore(startupError: .InvalidState(message: "No keychain"))
    let screen = OffscreenWindow(
      NewSessionContainer(connection: connection, form: try isolatedForm()) { _ in }, width: 700,
      height: 500)
    defer { screen.close() }
    try await settle(screen, untilShowing: "Cannot Start Sessions")
    #expect(try screen.shows("No keychain"))
  }

  @Test("Connect a Host opens its sheet with the server's command, and Done reads the hosts again")
  func connectHost() async throws {
    let server = newSessionServer()
    let screen = try await page(server)
    defer { screen.close() }
    try screen.choose(
      "Connect new host\u{2026}",
      in: menu(screen, at: Self.hostMenu, offering: "Connect new host\u{2026}"))
    try await settle(screen, untilShowing: "Run this on the machine the agents should work on:")
    #expect(!(try screen.shows("Use This Mac")), "only where the edition can run hosts")
    let before = server.requests("GET", "/v1/hosts").count
    try screen.clickControl(at: 2)  // Done, in the sheet's toolbar.
    try await settle(screen, until: "the catalog read") {
      server.requests("GET", "/v1/hosts").count > before
    }
  }

  @Test("Use This Mac appears where this edition can host, and shows the status it returns")
  func useThisMac() async throws {
    let asked = AskedURLs()
    let action = UseThisMachineAction { url in
      asked.urls.append(url)
      return "Connecting this Mac"
    }
    let screen = try await page(newSessionServer(), useThisMachine: action)
    defer { screen.close() }
    try screen.choose(
      "Connect new host\u{2026}",
      in: menu(screen, at: Self.hostMenu, offering: "Connect new host\u{2026}"))
    try await settle(screen, untilShowing: "Use This Mac")
    try screen.clickControl(at: 2)  // After the sheet's Close and the command's Copy.
    try await settle(screen, untilShowing: "Connecting this Mac")
    #expect(asked.urls.count == 1)
  }

  @Test("Create Custom Agent opens the form; Escape closes it with nothing chosen")
  func createAgent() async throws {
    let server = newSessionServer()
    let screen = try await page(server)
    defer { screen.close() }
    try screen.choose(
      "Create Custom Agent\u{2026}",
      in: menu(screen, at: Self.agentMenu, offering: "Create Custom Agent\u{2026}"))
    try await settle(screen, untilShowing: "Create Custom Agent")
    #expect(try screen.shows("Cancel"))
    _ = try pressShortcut(screen, keyCode: 53, characters: "\u{1b}", modifiers: [])
    try await pause(screen)
    #expect(server.requests("POST", "/v1/agents").isEmpty)
  }

  @Test("Set Up on a harness that isn't ready opens its sheet and reads what it needs")
  func setUpHarness() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/hosts",
      .json(
        #"{"hosts":[{"host_id":"mac","name":"Mac","status":"online","configured_harnesses":{"claude-native":false,"codex-native":false}}]}"#
      ))
    let screen = try await page(server)
    defer { screen.close() }
    try await settle(screen, untilShowing: "Set Up", contains: true)
    try screen.clickControl(at: 6)  // The notice's Set Up, under the composer's controls.
    try await settle(screen, until: "the setup catalog") {
      !server.requests("GET", "/v1/harnesses").isEmpty
    }
    _ = try pressShortcut(screen, keyCode: 53, characters: "\u{1b}", modifiers: [])
  }

  @Test("Choosing a model keeps an effort it offers; effort and approval mode are the form's")
  func modelAndEffort() async throws {
    let page = try await wired()
    let actions = page.container.actions(page.creation)
    page.form.selection.reasoningEffort = "high"
    actions.selectModel?("claude-native-fast")
    #expect(page.form.selection.model == "claude-native-fast")
    actions.selectEffort?("low")
    #expect(page.form.selection.reasoningEffort == "low")
    let extras = page.container.extraActions(page.creation)
    extras.selectApprovalMode?(ApprovalModeOption(id: "plan", label: "Plan"))
    #expect(page.form.selection.approvalMode == "plan")
    extras.setSmartRouting?(true)
    #expect(page.form.selection.smartRouting == true)
    extras.selectHost?(ComposerHost(id: "box", name: "box", kind: .machine, isOnline: true))
    #expect(page.form.selection.hostId == "box")
  }

  @Test("Remove on a staged file drops it; a chip with a bad id drops nothing")
  func removeAttachment() async throws {
    let page = try await wired()
    page.form.stage(
      [.data(Data([1]), suggestedName: "a.png", contentType: .png)], in: page.creation)
    let chip = try #require(page.form.attachmentChips(page.creation).first)
    let actions = page.container.actions(page.creation)
    var other = chip
    other.id = "not-a-uuid"
    actions.removeAttachment?(other)
    #expect(page.form.attachmentChips(page.creation).count == 1)
    actions.removeAttachment?(chip)
    #expect(page.form.attachmentChips(page.creation).isEmpty)
  }

  @Test("Dismiss clears the page's errors; with no session made it opens nothing")
  func dismissWithoutASession() async throws {
    let page = try await wired()
    page.form.attachmentError = "Could not read"
    page.form.projectError = "Could not read defaults"
    page.container.actions(page.creation).dismissDeliveryError?()
    #expect(page.form.attachmentError == nil)
    #expect(page.form.projectError == nil)
    #expect(page.opened.ids.isEmpty)
  }

  @Test("Browsing lists the chosen host's folder; a missing folder says why")
  func browse() async throws {
    let page = try await wired()
    let actions = page.container.optionActions(page.creation)
    let browse = try #require(actions.browse)
    let listing = try await browse(nil).get()
    #expect(listing.folders.map(\.name) == ["src"])
    let missing = await browse("/nowhere")
    guard case .failure(let error) = missing else {
      Issue.record("an unlisted folder must fail")
      return
    }
    #expect(!error.message.isEmpty)
    #expect(actions.isValidBranch?("feature/one") == true)
    #expect(actions.isValidBranch?("bad..name") == false)
    actions.selectFolder?("/work")
    #expect(page.form.folder == "/work")
  }

  @Test("A worktree choice goes into the request; a project's defaults fill the form")
  func worktreeAndProject() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/projects/p1", .json(#"{"id":"p1","name":"Alpha","config":{"workspace":"/alpha"}}"#))
    let page = try await wired(server)
    let actions = page.container.optionActions(page.creation)
    actions.selectFolder?("/work")
    actions.selectWorktree?(.new(branch: "feature", base: ""))
    #expect(page.form.selection.git?.branchName == "feature")

    page.connection.sessionList.projects = [ProjectSummary(id: "p1", name: "Alpha", icon: nil)]
    let select = try #require(page.container.optionActions(page.creation).selectProject)
    select("Alpha")
    try await eventually("the defaults") { page.form.folder == "/alpha" }
    #expect(page.form.project?.name == "Alpha")
    select(nil)
    #expect(page.form.project == nil)
    select("Gone")
    #expect(page.form.project == nil, "a name no longer listed clears the project")
  }

  @Test("A new sandbox offers no custom agent; a server that installs agents offers Import")
  func agentRowsFollowTheServer() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/info",
      .json(#"{"single_user":true,"accounts_enabled":false,"agent_install":true}"#))
    let page = try await wired(server)
    let extras = page.container.extraActions(page.creation)
    #expect(extras.createAgent != nil)
    #expect(extras.importAgentBundle != nil)
    page.form.isSandbox = true
    let onSandbox = page.container.extraActions(page.creation)
    #expect(onSandbox.createAgent == nil)
    #expect(onSandbox.importAgentBundle == nil)
  }
}

/// What the page opened.
@MainActor
private final class OpenedSessions {
  var ids: [String] = []
}

/// The server URLs Use This Mac was asked to host for.
@MainActor
private final class AskedURLs {
  var urls: [URL] = []
}

/// A page's actions and the stores they act on.
@MainActor
private struct WiredPage {
  let connection: ConnectionStore
  let creation: CreationStore
  let form: NewSessionForm
  let container: NewSessionContainer
  let opened: OpenedSessions
}
