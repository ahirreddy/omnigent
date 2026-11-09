import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Security
import Testing

@testable import OmnigentServices
@testable import OmnigentStores

/// A core that can't start leaves a store that says why, rather than one that crashes the app.
@MainActor
@Suite("A core that fails to start", .timeLimit(.minutes(1)))
struct ConnectionStartupTests {
  /// The real services, except a random generator that fails, which stops the core starting.
  private func servicesWithoutEntropy() -> HostServices {
    let live = HostServices.live()
    return HostServices(
      http: live.http, eventStreams: live.eventStreams, webSockets: live.webSockets,
      clock: live.clock, scheduler: live.scheduler, secureStore: InMemorySecureStore(),
      entropy: SystemEntropySource(fill: { _ in errSecNotAvailable }),
      settings: live.settings, managedPreferences: live.managedPreferences)
  }

  @Test("The failure shows on the connection, and connecting reports it instead of trying")
  func startupFails() async throws {
    let store = ConnectionStore(services: servicesWithoutEntropy())

    #expect(store.core == nil)
    let issue = try #require(store.issues.last)
    guard case .failed(let serverURL, let error) = store.phase else {
      Issue.record("expected a failed phase, got \(store.phase)")
      return
    }
    #expect(serverURL.isEmpty)
    #expect(error.message == issue.error.message)
    #expect(store.conversation("conv_a") == nil)

    await store.discover(serverURL: " http://127.0.0.1:6767 ")
    #expect(store.state == .failed(serverURL: "http://127.0.0.1:6767", message: error.message))
  }
}

/// The automatic-titles preference reaches the core when Settings changes it.
@MainActor
@Suite("The automatic titles preference", .timeLimit(.minutes(1)))
struct BackgroundTitlesWatchTests {
  private let suite = "ai.omnigent.tests.\(UUID().uuidString)"

  @Test("Its value applies at once, and again only when it changes")
  func appliesChanges() async throws {
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var applied: [Bool] = []
    let watch = ConnectionStore.watchBackgroundTitles(in: defaults) { applied.append($0) }
    defer { watch.cancel() }
    #expect(applied == [true], "on by default")

    // The watch subscribes when its task first runs, so a change may need saying again.
    try await eventually("the change") {
      defaults.set(false, forKey: SessionPreferences.backgroundTitlesKey)
      return applied == [true, false]
    }

    // Any other setting changing leaves it alone.
    defaults.set("other", forKey: "omnigent:unrelated")
    try await Task.sleep(for: .milliseconds(20))
    #expect(applied == [true, false])

    try await eventually("the change back") {
      defaults.set(true, forKey: SessionPreferences.backgroundTitlesKey)
      return applied == [true, false, true]
    }
  }
}

/// A saved draft that can't be checked against the core is reported, and stays saved.
@MainActor
@Suite("Reopening a saved draft", .timeLimit(.minutes(1)))
struct SavedDraftRestoreTests {
  @Test("A core that has just disconnected reports the failure on that session")
  func coreJustDisconnected() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
    let archive = ComposerDraftArchive(fileURL: folder.appending(path: "drafts.json"))
    let store = try await connectedStore(RouteServer())
    store.draftArchive = archive
    let account = try #require(store.connectedServer?.accountId)
    archive.record(SavedDraft(text: "kept"), account: account, session: "conv_b")
    archive.flush()

    // The store hears of the disconnect on a later turn, so it still reads as connected here.
    store.disconnect()
    let conversation = try #require(store.conversation("conv_b"))

    #expect(store.issues.last?.scope == .session(sessionId: "conv_b"))
    #expect(conversation.composer.text.isEmpty)
    #expect(archive.draft(account: account, session: "conv_b")?.text == "kept")
  }
}
