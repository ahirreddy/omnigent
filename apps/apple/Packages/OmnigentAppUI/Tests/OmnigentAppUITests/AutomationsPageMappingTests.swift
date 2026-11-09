import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The list and detail pages over what a server's JSON decodes to.
@MainActor
@Suite("Automations pages")
struct AutomationsPageMappingTests {
  private let now = Date(timeIntervalSince1970: 1_793_865_600)

  private func task(
    id: String = "t1", name: String = "Standup", state: String = "active",
    nextRun: String = #""2026-11-05T09:00:00Z""#, rrule: String = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
  ) -> String {
    #"""
    {"id":"\#(id)","name":"\#(name)","prompt":"p","rrule":"\#(rrule)","agent_id":"a1","timezone":"UTC","state":"\#(state)","next_run_at":\#(nextRun),"updated_at":1}
    """#
  }

  private func pages(tasks: [String]) async throws -> PagesStore {
    let connection = try await ConversationFixtures.connection(routes: [
      "/v1/info": .json(
        #"{"single_user":true,"accounts_enabled":false,"automations_enabled":true}"#),
      "/v1/scheduled-tasks": .json(
        #"{"scheduled_tasks":[\#(tasks.joined(separator: ","))]}"#),
    ])
    let pages = try #require(connection.pages)
    _ = await pages.loadOffered()
    await pages.loadAutomations()
    return pages
  }

  private func state(_ pages: PagesStore, filter: AutomationsFilter = .all, search: String = "")
    -> AutomationsViewState
  {
    AutomationsMapping.state(pages: pages, filter: filter, search: search, now: now)
  }

  @Test("Rows show the schedule and next run; a state the app doesn't know is named")
  func rows() async throws {
    let view = state(
      try await pages(tasks: [
        task(), task(id: "t2", name: "Odd", state: "exploded"),
        task(id: "t3", name: "Off", state: "paused"),
      ]))
    #expect(view.rows.count == 3)
    #expect(view.hasAny)
    #expect(!view.isLoading)
    let plain = try #require(view.rows.first { $0.id == "t1" })
    #expect(plain.nextRunText != nil)
    #expect(!plain.isPaused)
    let odd = try #require(view.rows.first { $0.id == "t2" })
    #expect(odd.scheduleText.hasSuffix(" \u{00B7} Exploded"))
    #expect(view.rows.first { $0.id == "t3" }?.isPaused == true)
  }

  @Test("Filter and search narrow the rows; a search matching nothing leaves none")
  func narrowing() async throws {
    let loaded = try await pages(tasks: [task(), task(id: "t2", name: "Off", state: "paused")])
    #expect(state(loaded, filter: .paused).rows.map(\.id) == ["t2"])
    #expect(state(loaded, filter: .active).rows.map(\.id) == ["t1"])
    #expect(state(loaded, search: "standup").rows.map(\.id) == ["t1"])
    let empty = state(loaded, search: String(repeating: "\u{1F600}", count: 100_000))
    #expect(empty.rows.isEmpty)
    #expect(empty.hasAny)
  }

  @Test("Hostile tasks either decode into rows or fail as a load error, never a crash")
  func hostileTasks() async throws {
    let long = String(repeating: "x", count: 300_000)
    for tasks in [
      [task(nextRun: "null")], [task(nextRun: #""not a date""#)], [task(nextRun: "-1")],
      [task(nextRun: String(Int64.max))], [task(nextRun: String(Int64.min))],
      [task(nextRun: #""99999-01-01T00:00:00Z""#)], [task(nextRun: #""0000-01-01T00:00:00Z""#)],
      [task(id: "", name: "", rrule: "")], [task(), task()], [task(name: long, rrule: long)],
      [task(rrule: "FREQ=EXPLODED")],
    ] {
      let loaded = try await pages(tasks: tasks)
      let view = state(loaded)
      #expect(view.loadError != nil || !view.rows.isEmpty, "\(tasks)")
      for automation in loaded.automations.value ?? [] {
        let detail = AutomationDetailMapping.state(
          automation, pages: loaded, now: now, calendar: .current)
        #expect(detail.id == automation.id)
        _ = AutomationsMapping.draft(automation)
      }
    }
  }

  @Test("A failed load is reported with no rows")
  func failedLoad() async throws {
    let connection = try await ConversationFixtures.connection()
    let pages = try #require(connection.pages)
    await pages.loadAutomations()
    let view = state(pages)
    #expect(view.loadError != nil)
    #expect(view.rows.isEmpty)
    #expect(!view.hasAny)
    #expect(view.triggers.isEmpty)
  }

  @Test("Agents offered skip what can't start a session, and an empty catalog is fine")
  func agents() {
    #expect(AutomationsMapping.agents(nil).isEmpty)
    let catalog = OmnigentCoreFFI.CreationCatalog(
      hosts: [],
      agents: [
        OmnigentCoreFFI.CreationAgent(
          id: "no", name: "No", harness: nil, description: nil, supportsCreation: false,
          pickerSection: .agent),
        OmnigentCoreFFI.CreationAgent(
          id: "", name: "", harness: nil, description: nil, supportsCreation: true,
          pickerSection: .agent),
      ])
    #expect(AutomationsMapping.agents(catalog).map(\.id) == [""])
    #expect(AutomationsMapping.newDraft(nil, catalog: catalog).agentID.isEmpty)
    #expect(AutomationsMapping.newDraft(nil, catalog: catalog).hostID.isEmpty)
  }

  @Test("A run's time reads at both ends of the 64-bit range, for every status")
  func extremeRuns() {
    let statuses: [AutomationRunStatus] = [
      .failed, .incomplete, .skipped, .starting, .running, .succeeded, .scheduled,
      .unknown(value: "exploded"),
    ]
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    for startedAt in [Int64.min, -1, 0, .max] {
      for status in statuses {
        let run = AutomationRun(
          id: "", status: status, inFlightLabel: nil, startedAt: startedAt, duration: nil,
          sessionId: nil, failureStage: nil, failureReason: nil, unread: false)
        let row = AutomationDetailMapping.row(run, now: now, calendar: calendar)
        #expect(!row.timestamp.isEmpty)
      }
    }
  }

  @Test("An automation's host falls back from its name to its id")
  func hosts() {
    var automation = Automation(
      id: "t", name: "", prompt: "", rrule: "", scheduleText: "", agentId: "gone", timezone: "",
      continuesSession: false, state: .active, nextRunAt: nil, lastRunAt: nil, lastRunStatus: nil,
      lastRunSessionId: nil, updatedAt: 0)
    automation.hostId = "ghost"
    #expect(AutomationDetailMapping.host(automation, catalog: nil) == "ghost")
    automation.hostId = ""
    #expect(AutomationDetailMapping.host(automation, catalog: nil).isEmpty)
  }

  @Test("A trigger id that names nothing has no source and no prompt")
  func unknownTriggers() {
    #expect(AutomationTriggerMapping.source("exploded") == nil)
    #expect(AutomationTriggerMapping.source("") == nil)
    var draft = AutomationDraftState()
    #expect(AutomationTriggerMapping.prompt(draft, sessionLink: "", sendsOverrides: false).isEmpty)
    draft.trigger = AutomationTriggerDraft(source: "exploded", event: "")
    #expect(AutomationTriggerMapping.prompt(draft, sessionLink: "", sendsOverrides: true).isEmpty)
  }
}
