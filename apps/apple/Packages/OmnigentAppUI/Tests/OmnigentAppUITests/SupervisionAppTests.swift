import OmnigentStores
import Testing
import UserNotifications

@testable import OmnigentAppUI

@MainActor
struct SupervisionAppTests {
  @Test("Approve requires authentication; Reply takes text; updates have no buttons")
  func categories() throws {
    let categories = SupervisionNotificationCategories.all
    #expect(Set(categories.map(\.identifier)) == Set(SupervisionCategory.allCases.map(\.rawValue)))
    let approval = try #require(
      categories.first { $0.identifier == SupervisionCategory.approvalWithReply.rawValue })
    #expect(
      approval.actions.map(\.identifier) == ["omnigent.approve", "omnigent.deny", "omnigent.reply"])
    let approve = try #require(approval.actions.first)
    #expect(approve.options.contains(.authenticationRequired))
    #expect(approval.actions[1].options.contains(.destructive))
    #expect(approval.actions[2] is UNTextInputNotificationAction)
    let update = try #require(
      categories.first { $0.identifier == SupervisionCategory.update.rawValue })
    #expect(update.actions.isEmpty)
  }

  @Test("Actions find the connection signed in to the notification's server")
  func registry() async throws {
    let registry = SupervisionConnections()
    let store = try await PreviewData.connectedDemoStore()
    let server = try #require(store.supervisedServerURL)
    #expect(registry.connection(for: server) == nil)
    registry.register(store)
    #expect(registry.connection(for: server) === store)
    #expect(registry.connection(for: server + "/") === store)
    #expect(registry.connection(for: "https://other.example.com") == nil)
    #expect(registry.serverURLs == [server])
  }

  @Test("Settings lists the asking scene's connection before its sign-in registers it")
  func settingsIncludesScene() async throws {
    let registry = SupervisionConnections()
    let store = try await PreviewData.connectedDemoStore()
    #expect(registry.connections(including: nil).isEmpty)
    #expect(
      registry.connections(including: store).map(ObjectIdentifier.init) == [
        ObjectIdentifier(store)
      ])
    #expect(registry.connections(including: store).count == 1)
  }
}
