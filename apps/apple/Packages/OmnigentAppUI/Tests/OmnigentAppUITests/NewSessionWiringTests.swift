import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import OmnigentAppUI

/// The new-session page's remaining actions.
@MainActor
@Suite("New session wiring", .serialized, .timeLimit(.minutes(1)))
struct NewSessionWiringTests {
  private struct Page {
    let creation: CreationStore
    let form: NewSessionForm
    let container: NewSessionContainer
    let connection: ConnectionStore
  }

  private func page(_ server: AppServer = newSessionServer()) async throws -> Page {
    let connection = try await signedInStore(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    return Page(
      creation: creation, form: form,
      container: NewSessionContainer(connection: connection, form: form) { _ in },
      connection: connection)
  }

  @Test("Dropping a file stages it, and acknowledging an unclear start clears it")
  func attachAndAcknowledge() async throws {
    let page = try await page()
    let actions = page.container.actions(page.creation)
    actions.addAttachments?([.data(Data([1]), suggestedName: "a.png", contentType: .png)])
    #expect(page.form.attachmentChips(page.creation).map(\.title) == ["a.png"])
    actions.acknowledgeUncertainDelivery?()
    #expect(page.creation.phase == .editing)
  }

  @Test("The repository and profile pickers change what a sandbox start sends")
  func sandboxPickers() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"accounts_enabled":false,"managed_sandboxes_enabled":true,"sandbox_providers":["modal"],"default_sandbox_provider":"modal","features":{"sandbox_profiles":true}}"#
      ))
    let page = try await page(server)
    page.form.sandboxes = page.connection.sandboxes()
    let options = page.container.optionActions(page.creation)
    let chosen = SandboxRepoChoice(url: "https://github.com/acme/app")
    options.repositories?.setRepos([chosen])
    #expect(page.form.sandbox.repos == [chosen])
    let profile = SandboxProfileOption(id: "p1", name: "Profile", revision: "1")
    options.profiles?.select(profile)
    #expect(page.form.sandbox.profile == profile)
  }

  @Test("With no sessions yet, Import goes to the server's import page or to Settings")
  func importSessions() async throws {
    let page = try await page()
    let connection = page.connection
    try await eventually("the list") { connection.sessionList.isLoaded }
    final class Asked {
      var urls: [URL] = []
      var destinations: [SettingsDestination] = []
    }
    let asked = Asked()
    let openURL = OpenURLAction { url in
      asked.urls.append(url)
      return .handled
    }
    let toWeb = try #require(page.container.importSessions(openURL, nil))
    toWeb()
    #expect(asked.urls.map(\.path) == ["/settings/import"])
    let openSettings = OpenSettingsDestinationAction { asked.destinations.append($0) }
    let toSettings = try #require(page.container.importSessions(openURL, openSettings))
    toSettings()
    #expect(asked.destinations.count == 1)
  }

  @Test("A new agent drafted in the sheet is what the page will start")
  func draftingAnAgent() async throws {
    SystemSideEffects.install()
    let server = newSessionServer()
    let row = sessionRow("conv_a", host: "mac", workspace: "/work/recent", updatedAt: 5)
    server.route(
      "/v1/sessions", method: "GET", .json(#"{"object":"list","data":[\#(row)],"has_more":false}"#))
    let connection = try await signedInStore(server)
    try await eventually("the list") { connection.sessionList.isLoaded }
    let form = try isolatedForm()
    let screen = OffscreenWindow(
      NewSessionContainer(connection: connection, form: form) { _ in }, width: 900, height: 700)
    defer { screen.close() }
    try await settle(screen, until: "the folder listing") {
      !server.requests("GET", "/v1/hosts/mac/filesystem").isEmpty
    }
    try await pause(screen, .milliseconds(150))
    let point = CGPoint(x: 676, y: 423)
    try screen.choose(
      "Create Custom Agent\u{2026}",
      in: menu(screen, at: point, offering: "Create Custom Agent\u{2026}"))
    try await settle(screen, untilShowing: "Create Custom Agent")
    try CustomAgentsScreenTests().fillIn("mine", in: screen)
    try screen.clickControl(at: screen.controlFrames.count - 1)
    try await settle(screen, until: "the draft") { form.startsPendingAgent }
    #expect(form.pendingChoice?.name == "mine")
  }
}
