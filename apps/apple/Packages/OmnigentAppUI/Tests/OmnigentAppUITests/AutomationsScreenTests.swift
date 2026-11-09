import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI

private let task =
  #"{"id":"t1","name":"Standup","prompt":"Summarize","rrule":"FREQ=DAILY;BYHOUR=9;BYMINUTE=0","agent_id":"ag_claude","timezone":"UTC","state":"active","next_run_at":"2099-11-05T09:00:00Z"}"#

/// A server with one automation and its agents and hosts.
private func automationsServer() -> AppServer {
  let server = newSessionServer()
  server.route("/v1/scheduled-tasks", method: "GET", .json(#"{"scheduled_tasks":[\#(task)]}"#))
  server.route("/v1/scheduled-tasks/t1/runs", .json(#"{"runs":[]}"#))
  return server
}

/// The Automations page, through its controls.
@MainActor
@Suite("Automations page", .serialized, .timeLimit(.minutes(1)))
struct AutomationsScreenTests {
  private final class Opened {
    var sessions: [String] = []
  }

  private func page(
    _ server: AppServer = automationsServer(),
    info: String =
      #"{"single_user":true,"automations_enabled":true,"features":{"automations_v2":true}}"#
  ) async throws -> (OffscreenWindow<AutomationsAdapter>, Opened) {
    SystemSideEffects.install()
    let connection = try await signedInStore(server)
    server.route("/v1/info", .json(info))
    _ = await connection.pages?.loadOffered()
    let opened = Opened()
    let defaults = try scratchDefaults()
    let key = AutomationsIntroPresenter.seenKey(
      baseURL: connection.connectedServer?.baseUrl, userID: connection.connectedServer?.userId)
    defaults.set(true, forKey: try #require(key))
    let screen = OffscreenWindow(
      AutomationsAdapter(
        connection: connection, open: { opened.sessions.append($0) }, defaults: defaults),
      width: 900, height: 1100)
    try await settle(screen, untilShowing: "Standup")
    return (screen, opened)
  }

  // Where things sit in a 900 by 1100 window with one automation and no sheet.
  private static let newMenu = CGPoint(x: 740, y: 34)
  private static let rowMenu = CGPoint(x: 835, y: 203)
  private static let row = CGPoint(x: 300, y: 200)
  private static let sheetSave = CGPoint(x: 410, y: 690)

  private func typeAFullDraft<Content: View>(_ screen: OffscreenWindow<Content>) throws {
    let name = try #require(
      screen.allViews.compactMap { $0 as? NSTextField }.first {
        $0.placeholderString == "daily-brief"
      })
    try screen.click(name)
    try screen.type("Report")
    let prompt = try #require(
      screen.allViews.compactMap { $0 as? NSTextField }.first {
        $0.placeholderString == "What should the agent do each run?"
      })
    try screen.click(prompt)
    try screen.type("Do it")
    screen.settle(0.05)
  }

  @Test("New automation: Create manually sends what's typed, on the first online host")
  func creating() async throws {
    let server = automationsServer()
    server.route("/v1/scheduled-tasks", method: "POST", .json(task, status: 201))
    let (screen, _) = try await page(server)
    defer { screen.close() }
    let menu = try menu(screen, at: Self.newMenu, offering: "Create manually")
    try screen.choose("Create manually", in: menu)
    try await settle(screen, untilShowing: "Create automation")
    try typeAFullDraft(screen)
    try screen.click(Self.sheetSave)
    try await settle(screen, until: "the create") {
      !server.requests("POST", "/v1/scheduled-tasks").isEmpty
    }
    let body = try #require(try server.posted("/v1/scheduled-tasks").first)
    #expect(body["name"] as? String == "Report")
    #expect(body["prompt"] as? String == "Do it")
    #expect(body["host_id"] as? String == "mac")
    #expect(body["agent_id"] as? String == "ag_claude")
    try await pause(screen, .milliseconds(300))
    #expect(try !screen.shows("Create automation"), "the sheet closes once saved")
  }

  @Test("A refused save stays in the sheet and says why")
  func aRefusedSave() async throws {
    let server = automationsServer()
    server.route(
      "/v1/scheduled-tasks", method: "POST", .json(#"{"detail":"bad schedule"}"#, status: 400))
    let (screen, _) = try await page(server)
    defer { screen.close() }
    let menu = try menu(screen, at: Self.newMenu, offering: "Create manually")
    try screen.choose("Create manually", in: menu)
    try await settle(screen, untilShowing: "Create automation")
    try typeAFullDraft(screen)
    try screen.click(Self.sheetSave)
    try await settle(screen, untilShowing: "bad schedule", contains: true)
    #expect(try screen.shows("Create automation"))
  }

  @Test("A suggestion opens the editor filled in; Cancel leaves")
  func suggestionAndCancel() async throws {
    let (screen, _) = try await page()
    defer { screen.close() }
    try screen.clickControl(at: 4)
    try await settle(screen, untilShowing: "Create automation")
    try pressShortcut(screen, keyCode: 53, characters: "\u{1b}", modifiers: [])
    try await pause(screen, .milliseconds(300))
    #expect(try !screen.shows("Create automation"))
  }

  @Test("A row's menu pauses, runs and deletes it")
  func rowMenu() async throws {
    let server = automationsServer()
    server.route("/v1/scheduled-tasks/t1/pause", method: "POST", .json(task))
    server.route(
      "/v1/scheduled-tasks/t1/run", method: "POST",
      .json(#"{"triggered":true,"id":"t1"}"#, status: 202))
    server.route("/v1/scheduled-tasks/t1", method: "DELETE", .json(#"{"deleted":true,"id":"t1"}"#))
    server.route("/v1/scheduled-tasks/t1", method: "PATCH", .json(task))
    let (screen, _) = try await page(server)
    defer { screen.close() }
    for (title, method, path) in [
      ("Pause", "PATCH", "/v1/scheduled-tasks/t1"),
      ("Run now", "POST", "/v1/scheduled-tasks/t1/run"),
    ] {
      try screen.choose(title, in: menu(screen, at: Self.rowMenu, offering: title))
      try await settle(screen, until: title) { !server.requests(method, path).isEmpty }
      try await pause(screen, .milliseconds(100))
    }
    try screen.choose("Delete", in: menu(screen, at: Self.rowMenu, offering: "Delete"))
    try await settle(screen, until: "the delete") {
      !server.requests("DELETE", "/v1/scheduled-tasks/t1").isEmpty
    }
  }

  @Test("A row's Edit opens it; saving sends the change to it")
  func editing() async throws {
    let server = automationsServer()
    server.route("/v1/scheduled-tasks/t1", method: "PATCH", .json(task))
    let (screen, _) = try await page(server)
    defer { screen.close() }
    try screen.choose("Edit", in: menu(screen, at: Self.rowMenu, offering: "Edit"))
    try await settle(screen, untilShowing: "Save changes")
    try screen.clickControl(at: screen.controlFrames.count - 1)
    try await settle(screen, until: "the save") {
      !server.requests("PATCH", "/v1/scheduled-tasks/t1").isEmpty
    }
    #expect(try server.patched("/v1/scheduled-tasks/t1").first?["name"] as? String == "Standup")
  }

  @Test("A row opens its run history; Back returns")
  func detail() async throws {
    let server = automationsServer()
    server.route(
      "/v1/scheduled-tasks/t1/runs",
      .json(
        #"{"runs":[{"id":"r1","scheduled_task_id":"t1","status":"succeeded","scheduled_at":50,"fired_at":50,"finished_at":152,"conversation_id":"c2"},{"id":"r2","scheduled_task_id":"t1","status":"failed","scheduled_at":10,"error_code":"no_online_host"}]}"#
      ))
    let (screen, opened) = try await page(server)
    defer { screen.close() }
    try screen.click(Self.row)
    try await settle(screen, untilShowing: "1m 42s")
    #expect(try screen.shows("Host \u{00B7} None of your hosts was online."))
    // Its controls: Back, Edit, Delete, Run, Pause, then the run's row.
    try screen.clickControl(at: 5)
    try await pause(screen, .milliseconds(100))
    #expect(opened.sessions == ["c2"], "the run opens its session")
    try screen.clickControl(at: 0)
    try await settle(screen, untilShowing: "Suggestions")
  }

  @Test("The page's own buttons run, edit, pause and delete it, then go back")
  func detailActions() async throws {
    SystemSideEffects.reset()
    let server = automationsServer()
    server.route(
      "/v1/scheduled-tasks/t1/run", method: "POST",
      .json(#"{"triggered":true,"id":"t1"}"#, status: 202))
    server.route("/v1/scheduled-tasks/t1", method: "PATCH", .json(task))
    server.route("/v1/scheduled-tasks/t1", method: "DELETE", .json(#"{"deleted":true,"id":"t1"}"#))
    let (screen, _) = try await page(server)
    defer { screen.close() }
    try screen.click(Self.row)
    try await settle(screen, untilShowing: "Run history")
    let reads = server.requests("GET", "/v1/scheduled-tasks/t1/runs").count
    // Edit, Delete and Run are the three controls at the top right.
    try screen.clickControl(at: 3)
    try await settle(screen, until: "the run") {
      !server.requests("POST", "/v1/scheduled-tasks/t1/run").isEmpty
    }
    try await settle(screen, until: "the history to be read again") {
      server.requests("GET", "/v1/scheduled-tasks/t1/runs").count > reads
    }
    try screen.clickControl(at: 4)
    try await settle(screen, until: "the pause") {
      !server.requests("PATCH", "/v1/scheduled-tasks/t1").isEmpty
    }
    try await pause(screen, .milliseconds(100))
    try screen.clickControl(at: 1)
    try await settle(screen, untilShowing: "Save changes")
    try pressShortcut(screen, keyCode: 53, characters: "\u{1b}", modifiers: [])
    try await pause(screen, .milliseconds(300))
    try screen.clickControl(at: 2)
    try await settle(screen, until: "the delete") {
      !server.requests("DELETE", "/v1/scheduled-tasks/t1").isEmpty
    }
    try await settle(screen, untilShowing: "Suggestions")
  }

}

extension AutomationsScreenTests {
  @Test("A trigger starts from its template")
  func aTrigger() async throws {
    let (screen, _) = try await page(
      info:
        #"{"single_user":true,"automations_enabled":true,"scheduled_task_session_modes":true,"features":{"automations_v2":true,"session_orchestration":true}}"#
    )
    defer { screen.close() }
    try screen.choose(
      "GitHub issues", in: menu(screen, at: Self.newMenu, offering: "GitHub issues"))
    try await settle(screen, untilShowing: "Create automation")
    let shown = try screen.shownText()
    #expect(shown.contains { $0.localizedCaseInsensitiveContains("GitHub") }, "\(shown.prefix(20))")
  }

  @Test("The editor offers what the server does: sandbox, projects and an agent change's note")
  func editorContext() async throws {
    let server = automationsServer()
    server.route(
      "/v1/hosts/mac/harnesses/claude-native/model-options",
      .json(
        #"{"models":[{"id":"listed","model":"listed","displayName":"Listed"},{"id":"hidden","model":"hidden","hidden":true}]}"#
      ))
    server.route("/v1/sessions/projects", .json(#"[{"id":"p1","name":"Alpha"}]"#))
    let connection = try await signedInStore(server)
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"automations_enabled":true,"managed_sandboxes_enabled":true,"scheduled_task_projects":true,"features":{"automations_v2":true}}"#
      ))
    let pages = try #require(connection.pages)
    _ = await pages.loadOffered()
    await pages.loadAutomations()
    await pages.loadAutomationCatalog()
    await pages.loadAutomationProjects()
    await pages.loadAutomationModels(agentID: "ag_claude", hostID: "mac")
    var draft = AutomationDraftState()
    draft.agentID = "ag_claude"
    draft.hostID = "mac"
    let saved = try #require(pages.automations.value?.first)

    var context = AutomationEditorMapping.context(
      pages: pages,
      inputs: AutomationEditorMapping.Inputs(draft: draft, sessionLink: "", saveError: "Nope"))
    #expect(context.sandboxLabel == "New Sandbox")
    #expect(context.hosts.map(\.id) == ["mac", "box"])
    #expect(context.supportsProjects)
    #expect(context.anchoredScheduling)
    #expect(context.error == "Nope")
    #expect(context.overrides?.models.map(\.name) == ["Listed"], "a hidden model isn't offered")
    #expect(!context.hasContinuingSession)

    draft.agentID = "ag_codex"
    context = AutomationEditorMapping.context(
      pages: pages,
      inputs: AutomationEditorMapping.Inputs(draft: draft, saved: saved, sessionLink: ""))
    #expect(context.isEditing)
    #expect(context.overrides == nil, "only Claude Code takes these")
    #expect(context.agentNote == "Future runs use Codex; past runs keep the agent they ran with")
  }

  @Test("What blocks Save is said in the form")
  func blockers() {
    var draft = AutomationDraftState()
    #expect(
      AutomationEditorMapping.blocker(draft, isEditing: false)
        == "Pick the host this automation runs on.")
    #expect(AutomationEditorMapping.blocker(draft, isEditing: true) == nil)
    draft.workspace = "/w"
    #expect(
      AutomationEditorMapping.blocker(draft, isEditing: true)
        == "Pick a host before pinning a workspace.")
    draft.runsInSandbox = true
    #expect(AutomationEditorMapping.blocker(draft, isEditing: false) == nil)
  }

  @Test("The guide shows once per server and user, and closing it marks it seen")
  func theGuide() async throws {
    let server = automationsServer()
    let connection = try await signedInStore(server)
    let defaults = try scratchDefaults()
    let screen = OffscreenWindow(
      AutomationsAdapter(connection: connection, open: { _ in }, defaults: defaults),
      width: 900, height: 1100)
    defer { screen.close() }
    try await settle(screen, untilShowing: "Introducing Automations")
    let key = try #require(
      AutomationsIntroPresenter.seenKey(
        baseURL: connection.connectedServer?.baseUrl, userID: connection.connectedServer?.userId))
    #expect(!defaults.bool(forKey: key))
    try screen.clickControl(at: screen.controlFrames.count - 2)
    try await settle(screen, until: "the guide to be seen") { defaults.bool(forKey: key) }
    #expect(AutomationsIntroPresenter.seenKey(baseURL: nil, userID: "u") == nil)
  }

  @Test("A list that can't be read says why and offers to try again")
  func failure() async throws {
    let server = automationsServer()
    server.route("/v1/scheduled-tasks", method: "GET", .json(#"{"detail":"down"}"#, status: 500))
    let connection = try await signedInStore(server)
    server.route("/v1/info", .json(#"{"single_user":true,"automations_enabled":true}"#))
    let screen = OffscreenWindow(
      AutomationsAdapter(connection: connection, open: { _ in }, defaults: try scratchDefaults()),
      width: 900, height: 1100)
    defer { screen.close() }
    try await settle(screen, untilShowing: "Couldn\u{2019}t load automations.")
    let reads = server.requests("GET", "/v1/scheduled-tasks").count
    try screen.clickControl(at: 2)
    try await settle(screen, until: "another read") {
      server.requests("GET", "/v1/scheduled-tasks").count > reads
    }
  }
}
