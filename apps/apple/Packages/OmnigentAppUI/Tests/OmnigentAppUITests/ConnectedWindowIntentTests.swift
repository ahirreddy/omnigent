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

/// What the mounted window shows between a sidebar edit and the server's answer to it.
extension ConnectedWindowFlowTests {
  private static let titles = ["conv_a": "Alpha", "conv_b": "Beta", "conv_c": "Gamma"]

  private func titledRow(_ id: String, archived: Bool = false) -> String {
    let row = sessionRow(
      id, host: "mac", workspace: "/work/\(id)", updatedAt: 30, archived: archived)
    return #"{"title":"\#(Self.titles[id] ?? id)","# + row.dropFirst()
  }

  /// The three sessions with titles, so a row can be told from the others on screen.
  private func titledServer() -> AppServer {
    let server = threeSessionServer()
    let ids = Self.titles.keys.sorted()
    let rows = ids.map { titledRow($0) }.joined(separator: ",")
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[\#(rows)],"has_more":false}"#))
    for id in ids { server.route("/v1/sessions/\(id)", .json(titledRow(id))) }
    return server
  }

  /// A window on `conv_a` that showed `conv_b` before it.
  private func mountedOnAlpha(_ server: AppServer) async throws -> Mounted {
    let mounted = try await mounted(server)
    mounted.session.tabs.showChat("conv_b")
    mounted.session.tabs.showChat("conv_a")
    try await settle(mounted.screen, untilShowing: "Alpha")
    return mounted
  }

  @Test("An archive the server holds: the row is gone, Undo is offered, the tabs wait")
  func archiveBeforeTheAnswer() async throws {
    let server = titledServer()
    let gate = server.hold("/v1/sessions/conv_a", method: "PATCH")
    server.route("/v1/sessions/conv_a", method: "PATCH", .json(titledRow("conv_a", archived: true)))
    let mounted = try await mountedOnAlpha(server)
    defer { mounted.screen.close() }
    let tabs = mounted.session.tabs

    mounted.view.edit(.archive(["conv_a"], true))
    try await settle(mounted.screen, until: "the write") { gate.arrivals == 1 }
    try await settle(mounted.screen, untilShowing: "Archived 1 session")
    try await settle(mounted.screen, until: "the row to leave") {
      (try? mounted.screen.shows("Alpha")) == false
    }
    #expect(try mounted.screen.shows("Beta"), "the other rows stay")
    #expect(tabs.page == .session("conv_b"), "the window moved to the session shown before")
    #expect(tabs.groups["conv_a"] != nil, "the tabs wait for the server")
    #expect(server.requests("PATCH", "/v1/sessions/conv_a").count == 1)
    #expect(mounted.session.connection.sessionList.editError == nil)

    gate.release()
    try await settle(mounted.screen, until: "the tabs to leave") { tabs.groups["conv_a"] == nil }
    #expect(try mounted.screen.shows("Archived 1 session"), "Undo stays offered")
    #expect(tabs.page == .session("conv_b"))
  }

  @Test("An archive the server refuses: the row, the session and its tabs come back")
  func archiveRefusedInAWindow() async throws {
    let server = titledServer()
    let gate = server.hold("/v1/sessions/conv_a", method: "PATCH")
    server.route(
      "/v1/sessions/conv_a", method: "PATCH", .json(#"{"detail":"Not yours"}"#, status: 409))
    let mounted = try await mountedOnAlpha(server)
    defer {
      mounted.screen.close()
      SystemSideEffects.reset()
    }
    let tabs = mounted.session.tabs

    mounted.view.edit(.archive(["conv_a"], true))
    try await settle(mounted.screen, until: "the write") { gate.arrivals == 1 }
    try await settle(mounted.screen, until: "the window to leave") {
      tabs.page == .session("conv_b")
    }
    gate.release()
    try await settle(mounted.screen, until: "the window to return") {
      tabs.page == .session("conv_a")
    }
    try await settle(mounted.screen, untilShowing: "Alpha")
    try await settle(mounted.screen, until: "the alert") {
      SystemSideEffects.record.alertMessages.contains("Could Not Archive the Session")
    }
    #expect(tabs.groups["conv_a"] != nil)
    #expect(mounted.model.undo == nil, "there is nothing to undo")
    #expect(try !mounted.screen.shows("Archived 1 session"))
  }

  @Test("Retry in the alert of a refused rename sends the rename again")
  func retryFromTheAlert() async throws {
    let server = titledServer()
    let first = server.hold("/v1/sessions/conv_b", method: "PATCH")
    server.route(
      "/v1/sessions/conv_b", method: "PATCH", .json(#"{"detail":"Not yours"}"#, status: 409))
    let mounted = try await mountedOnAlpha(server)
    defer {
      mounted.screen.close()
      SystemSideEffects.reset()
    }
    let list = mounted.session.connection.sessionList

    mounted.view.rename("conv_b", to: "Renamed")
    try await settle(mounted.screen, untilShowing: "Renamed")
    try await settle(mounted.screen, until: "the write") { first.arrivals == 1 }
    let second = server.hold("/v1/sessions/conv_b", method: "PATCH")
    SystemSideEffects.answer(alert: .alertSecondButtonReturn)
    first.release()
    try await settle(mounted.screen, until: "the rename again") { second.arrivals == 1 }
    #expect(SystemSideEffects.record.alertMessages == ["Could Not Rename the Session"])

    SystemSideEffects.answer(alert: .alertFirstButtonReturn)
    server.route(
      "/v1/sessions/conv_b", method: "PATCH",
      .json(titledRow("conv_b").replacingOccurrences(of: "Beta", with: "Renamed")))
    second.release()
    try await settle(mounted.screen, until: "the answer") {
      list.editError == nil && list.session("conv_b")?.title == "Renamed"
    }
    try await pause(mounted.screen)
    #expect(try mounted.screen.shows("Renamed"))
    #expect(SystemSideEffects.record.alertMessages.count == 1, "the second try was saved")
  }

  @Test("A delete the server holds hides the row and keeps the tabs until it answers")
  func deleteBeforeTheAnswer() async throws {
    let server = titledServer()
    let refused = server.hold("/v1/sessions/conv_b", method: "DELETE")
    server.route(
      "/v1/sessions/conv_b", method: "DELETE", .json(#"{"detail":"Still running"}"#, status: 409))
    let mounted = try await mountedOnAlpha(server)
    defer {
      mounted.screen.close()
      SystemSideEffects.reset()
    }
    let tabs = mounted.session.tabs
    let list = mounted.session.connection.sessionList
    let row = OmnigentUIComponents.SessionSummary(try #require(list.session("conv_b")))

    mounted.view.sessionListActions.delete?(row)
    try await settle(mounted.screen, until: "the write") { refused.arrivals == 1 }
    try await settle(mounted.screen, until: "the row to leave") {
      (try? mounted.screen.shows("Beta")) == false
    }
    #expect(tabs.groups["conv_b"] != nil, "the tabs wait for the server")

    let saved = server.hold("/v1/sessions/conv_b", method: "DELETE")
    refused.release()
    try await settle(mounted.screen, untilShowing: "Beta")
    try await settle(mounted.screen, until: "the alert") {
      SystemSideEffects.record.alertMessages == ["Could Not Update the Session"]
    }
    try await pause(mounted.screen)
    #expect(tabs.groups["conv_b"] != nil, "a refused delete keeps the tabs")

    server.route("/v1/sessions/conv_b", method: "DELETE", .json(#"{"deleted":true}"#))
    mounted.view.sessionListActions.delete?(row)
    try await settle(mounted.screen, until: "the second write") { saved.arrivals == 1 }
    try await pause(mounted.screen)
    #expect(tabs.groups["conv_b"] != nil)
    saved.release()
    try await settle(mounted.screen, until: "the tabs to leave") { tabs.groups["conv_b"] == nil }
    #expect(try !mounted.screen.shows("Beta"))
  }
}
