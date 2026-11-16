import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentServices
import OmnigentStores
import Testing

@testable import OmnigentAppUI

/// Databricks through the published client's loopback redirect with its page in the sheet, as on
/// iOS: the listener receives the redirect, and the sheet is dismissed.
extension SignInSheetTests {
  private final class LoopbackSheet {
    var pages: [(URL, WebAuthenticationCallback)] = []
    var dismissed = 0
    var listeners: [LoopbackRedirectListener] = []
  }

  private func loopbackSettings() -> DatabricksOAuthSettings {
    DatabricksOAuthSettings(clientId: "omnigent", redirectUrl: "http://localhost")
  }

  /// A sheet whose browser, once the user signs in, requests the redirect with a code and
  /// `state` (the page's own unless given), then stays open until it is dismissed.
  private func loopbackSheet(
    _ recorded: LoopbackSheet, state: String? = nil
  ) -> SignInController.AuthenticateInSheet {
    { url, callback throws(WebAuthenticationError) in
      recorded.pages.append((url, callback))
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      guard let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
        let pageState = state ?? items.first(where: { $0.name == "state" })?.value,
        let target = URL(string: "\(redirect)/?code=abc&state=\(pageState)")
      else { throw .failed(message: "No redirect in \(url)") }
      let session = URLSession(configuration: .ephemeral)
      defer { session.finishTasksAndInvalidate() }
      do {
        _ = try await session.data(from: target)
        try await Task.sleep(for: .seconds(30))
      } catch {
        guard Task.isCancelled else { throw .failed(message: "The redirect failed: \(error)") }
        recorded.dismissed += 1
        throw .cancelled
      }
      throw .failed(message: "The sheet was never dismissed.")
    }
  }

  private func loopbackController(
    sheet: @escaping SignInController.AuthenticateInSheet, recorded: LoopbackSheet
  ) throws -> SignInController {
    let controller = try controller(
      databricksServer(), databricks: loopbackSettings(), sheet: sheet)
    controller.databricksLoopbackPage = .sheet
    controller.makeListener = {
      let listener = LoopbackRedirectListener()
      recorded.listeners.append(listener)
      return listener
    }
    return controller
  }

  @Test("A loopback sign-in in the sheet completes from the listener and dismisses the sheet")
  func databricksLoopbackInTheSheet() async throws {
    let recorded = LoopbackSheet()
    let controller = try loopbackController(sheet: loopbackSheet(recorded), recorded: recorded)
    try await startDatabricks(controller)
    try await eventually("signing in") { controller.store.isSignedIn && controller.method == nil }

    #expect(controller.store.connectedServer?.userId == "ada")
    #expect(recorded.dismissed == 1)
    let (page, callback) = try #require(recorded.pages.first)
    #expect(page.path() == "/oidc/v1/authorize")
    #expect(callback == .customScheme(SignInController.unmatchedCallbackScheme))
    let redirect = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == "redirect_uri" }?.value
    #expect(redirect?.hasPrefix("http://localhost:") == true, "\(redirect ?? "none")")
    #expect(reason(controller) == nil)
    #expect(controller.state.notice == nil)
  }

  @Test("A redirect whose state isn't the sign-in's is refused, and the sheet still closes")
  func databricksLoopbackForgedState() async throws {
    let recorded = LoopbackSheet()
    let controller = try loopbackController(
      sheet: loopbackSheet(recorded, state: "forged"), recorded: recorded)
    try await startDatabricks(controller)
    try await eventually("the refusal") { reason(controller) != nil && controller.method == nil }
    #expect(!controller.store.isSignedIn)
    #expect(recorded.dismissed == 1)
  }

  @Test("Closing the sheet first is a note and stops the listener; a sheet failure says why")
  func databricksLoopbackSheetEnds() async throws {
    let recorded = LoopbackSheet()
    let closed = try loopbackController(
      sheet: { _, _ throws(WebAuthenticationError) in throw .cancelled }, recorded: recorded)
    try await startDatabricks(closed)
    try await eventually("the note") { closed.state.notice != nil && closed.method == nil }
    #expect(closed.state.notice == "Sign-in was cancelled.")
    #expect(reason(closed) == nil)
    let listener = try #require(recorded.listeners.first)
    await #expect(throws: LoopbackRedirectError.cancelled) { try await listener.waitForCallback() }

    let failed = try loopbackController(
      sheet: { _, _ throws(WebAuthenticationError) in throw .failed(message: "No browser engine") },
      recorded: LoopbackSheet())
    try await startDatabricks(failed)
    try await eventually("the failure") { reason(failed) == "No browser engine" }
    #expect(failed.state.notice == nil)
  }

  @Test("A listener that can't start shows no sheet and says why")
  func databricksLoopbackListenerFails() async throws {
    let recorded = LoopbackSheet()
    let controller = try loopbackController(sheet: loopbackSheet(recorded), recorded: recorded)
    controller.makeListener = {
      let listener = LoopbackRedirectListener()
      listener.cancel()
      return listener
    }
    try await startDatabricks(controller)
    try await eventually("the failure") { reason(controller) != nil }
    #expect(reason(controller)?.hasPrefix("Could not receive the browser sign-in") == true)
    #expect(recorded.pages.isEmpty)
  }

  @Test("A listener that stops while the sheet is open closes the sheet and says nothing")
  func databricksLoopbackListenerStops() async throws {
    let recorded = LoopbackSheet()
    let controller = try loopbackController(
      sheet: { url, callback throws(WebAuthenticationError) in
        recorded.pages.append((url, callback))
        recorded.listeners.first?.cancel()
        do {
          try await Task.sleep(for: .seconds(30))
        } catch {
          recorded.dismissed += 1
          throw .cancelled
        }
        throw .failed(message: "The sheet was never dismissed.")
      }, recorded: recorded)
    try await startDatabricks(controller)
    try await eventually("the sheet to close") {
      recorded.dismissed == 1 && controller.method == nil
    }
    #expect(reason(controller) == nil)
    #expect(controller.state.notice == nil)
    #expect(!controller.store.isSignedIn)
  }
}
