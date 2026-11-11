import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

@MainActor
@Suite("Composer state")
struct ComposerAdapterStateTests {
  private typealias Fixtures = ConversationFixtures

  @Test("Why a session can't take a message, most final reason first")
  func availability() async throws {
    let loading = try await Fixtures.store(hydrated: false)
    #expect(ComposerAdapter.availability(loading).reason?.contains("load") == true)
    #expect(ComposerAdapter.availability(try await Fixtures.store()) == .available)

    let archived = try await Fixtures.store(header: Fixtures.header(archived: true))
    #expect(ComposerAdapter.availability(archived).reason == "This session is archived.")
    #expect(ComposerAdapter.isReadOnly(archived))

    let both = try await Fixtures.store(header: Fixtures.header(readOnly: true, archived: true))
    #expect(ComposerAdapter.availability(both).reason?.contains("read this session") == true)

    both.closed()
    #expect(ComposerAdapter.availability(both).reason?.contains("no longer available") == true)
    #expect(ComposerAdapter.isReadOnly(both))
  }

  @Test("Delivery prefers a send in flight, then an uncertain send, then a failure")
  func delivery() async throws {
    let composer = try await Fixtures.store().composer
    let failure = CoreError.InvalidState(message: "Refused")
    #expect(ComposerAdapter.delivery(composer, dismissed: nil) == .idle)

    composer.lastError = failure
    #expect(ComposerAdapter.delivery(composer, dismissed: nil) == .failed(message: "Refused"))
    #expect(ComposerAdapter.delivery(composer, dismissed: failure) == .idle)
    // Only the failure that was dismissed stays hidden.
    #expect(
      ComposerAdapter.delivery(composer, dismissed: .InvalidState(message: "Older"))
        == .failed(message: "Refused"))

    composer.isBlocked = true
    #expect(ComposerAdapter.delivery(composer, dismissed: nil) == .uncertain(message: "Refused"))
    guard case .uncertain(let generic) = ComposerAdapter.delivery(composer, dismissed: failure)
    else {
      Issue.record("a blocked composer reads as uncertain")
      return
    }
    #expect(generic.contains("may not have been delivered"))

    composer.isSending = true
    #expect(ComposerAdapter.delivery(composer, dismissed: nil) == .sending)
  }

  @Test("A message that waits to be restored keeps its banner until it is restored")
  func offeredMessage() async throws {
    let store = try await Fixtures.store()
    let composer = store.composer
    func isOffered() -> Bool {
      ComposerAdapter.state(store, isStopping: false, dismissedError: nil).offersUnsentMessage
    }
    #expect(!isOffered())

    var offer = UnsentSend(draft: SavedDraft(text: "the first"))
    offer.failure = "Refused"
    composer.unsentOffers = [offer]
    composer.text = "newer"
    let failure = CoreError.InvalidState(message: "A newer failure")
    composer.lastError = failure
    #expect(
      ComposerAdapter.delivery(composer, dismissed: nil) == .failed(message: "A newer failure"))
    let state = ComposerAdapter.state(store, isStopping: false, dismissedError: failure)
    #expect(state.offersUnsentMessage)
    #expect(state.delivery == .failed(message: "Refused"))

    ComposerAdapter.extras(composer, isRunning: { true }).restoreUnsent?()
    #expect(composer.text == "newer\n\nthe first")
    #expect(ComposerAdapter.delivery(composer, dismissed: failure) == .idle)
    #expect(!isOffered())
  }

  @Test("Every upload status has a chip; the largest size stays representable")
  func attachments() {
    func attachment(_ status: UploadStatus, isImage: Bool = false) -> DraftAttachmentState {
      ComposerAdapter.attachment(
        OmnigentCoreFFI.DraftAttachment(
          id: 7, filename: "a.png", mediaType: "", byteCount: 1, isImage: isImage, status: status)
      ).state
    }
    #expect(attachment(.staged) == .ready)
    #expect(attachment(.uploading(progress: .nan)) == .uploading(progress: nil))
    #expect(attachment(.uploaded(fileId: "")) == .uploaded)
    #expect(attachment(.failed(message: "no")) == .failed(message: "no"))
    #expect(attachment(.uncertain(message: "maybe")) == .failed(message: "maybe"))

    let huge = ComposerAdapter.attachment(
      OmnigentCoreFFI.DraftAttachment(
        id: .max, filename: "", mediaType: "", byteCount: .max, isImage: true, status: .staged))
    #expect(huge.byteCount == .max)
    #expect(huge.id == String(UInt64.max))
    #expect(huge.kind == .image)
    #expect(huge.title.isEmpty)
  }

  @Test("A session's reported settings fill the menus until the composer loads its own")
  func settingsConfiguration() async throws {
    let reported = ComposerAdapter.configuration(
      Fixtures.settings(
        routingMode: "on", modelOverride: .value(value: "opus"), effort: .value(value: "high")))
    #expect(reported.selectedModelId == "opus")
    #expect(reported.selectedEffort == "high")
    #expect(reported.smartRouting == .enabled)

    let unreported = ComposerAdapter.configuration(
      Fixtures.settings(routingMode: "exploded", modelOverride: .harnessDefault))
    #expect(unreported.selectedModelId == nil)
    #expect(unreported.selectedEffort == nil)
    #expect(unreported.smartRouting != .enabled)

    let store = try await Fixtures.store(header: Fixtures.header(settings: Fixtures.settings()))
    let fromHeader = ComposerAdapter.state(store, isStopping: false, dismissedError: nil)
    #expect(fromHeader.configuration?.harness == "claude-sdk")
    store.composer.configuration = Fixtures.configuration(harness: "exploded-harness")
    let fromComposer = ComposerAdapter.state(store, isStopping: false, dismissedError: nil)
    #expect(fromComposer.configuration?.harness == "exploded-harness")
    #expect(fromComposer.configuration?.modelOptions.isEmpty == true)
  }

  @Test("Smart Routing shows while it is on, whatever the core offers")
  func smartRouting() async throws {
    let composer = try await Fixtures.store().composer
    #expect(ComposerAdapter.smartRouting(composer) == .unavailable)
    composer.configuration = Fixtures.configuration(routingMode: "on")
    #expect(ComposerAdapter.smartRouting(composer) == .enabled)
    composer.configuration = Fixtures.configuration(routingMode: "exploded")
    #expect(ComposerAdapter.smartRouting(composer) != .enabled)
  }

  @Test("Only a path is shown as the directory; a sandbox section marks the host as cloud")
  func executionContext() async throws {
    let store = try await Fixtures.store(
      sections: [Fixtures.section("sandbox", summary: "e2b")])
    store.composer.workspace = "/work/project"
    let cloud = ComposerAdapter.context(store, server: nil)
    #expect(cloud.directory == "/work/project")
    #expect(cloud.hostKind == .cloud)
    #expect(cloud.sandbox == "Managed sandbox \u{00B7} e2b")

    for (workspace, directory) in [
      ("~/src", "~/src"), ("relative/path", nil), ("", nil), ("https://x/y", nil),
    ] as [(String, String?)] {
      store.composer.workspace = workspace
      #expect(ComposerAdapter.context(store, server: nil).directory == directory)
    }

    let bare = ComposerAdapter.context(try await Fixtures.store(), server: nil)
    #expect(bare.hostKind == .machine)
    #expect(bare.harness == nil)
    #expect(bare.isHostOnline == nil)
    #expect(bare.sandbox == nil)
    #expect(bare.branch == nil)
  }

  @Test("The stream's state is shown unless the session has its own banner")
  func connection() async throws {
    let store = try await Fixtures.store()
    store.linkChanged(.live)
    #expect(ComposerAdapter.connection(store) == nil)
    store.linkChanged(.connecting)
    #expect(ComposerAdapter.connection(store)?.isFailure == false)

    let failure = CoreError.InvalidState(message: "gone")
    for link: LinkState in [.closed, .stopped, .failed(error: failure)] {
      store.linkChanged(link)
      #expect(ComposerAdapter.connection(store)?.isFailure == true)
    }

    let superseded = try await Fixtures.store()
    superseded.linkChanged(.failed(error: failure))
    superseded.superseded(by: "")
    #expect(ComposerAdapter.connection(superseded) == nil)
    let closed = try await Fixtures.store()
    closed.linkChanged(.failed(error: failure))
    closed.closed()
    #expect(ComposerAdapter.connection(closed) == nil)
  }

  @Test("A reconnect's wait reads sensibly at both ends of its range")
  func reconnectDelays() async throws {
    let store = try await Fixtures.store()
    let failure = CoreError.InvalidState(message: "down")
    store.linkChanged(.reconnecting(reason: failure, failures: 1, delayMs: 0))
    #expect(ComposerAdapter.connection(store)?.message == "Reconnecting in 1s: down")
    store.linkChanged(.reconnecting(reason: failure, failures: .max, delayMs: .max))
    let longest = try #require(ComposerAdapter.connection(store)?.message)
    #expect(longest.contains("attempt \(UInt32.max)"))
    #expect(longest.hasPrefix("Reconnecting in "))
    #expect(store.errors.count == 2)
  }

  @Test("A failed stream asks to reconnect; a pending question comes first")
  func placeholder() async throws {
    let store = try await Fixtures.store()
    #expect(ComposerAdapter.statusPlaceholder(store, connection: nil) == nil)
    let failed = ComposerConnectionNotice(message: "x", isFailure: true)
    #expect(
      ComposerAdapter.statusPlaceholder(store, connection: failed)?.contains("offline") == true)
    let healthy = ComposerConnectionNotice(message: "x")
    #expect(ComposerAdapter.statusPlaceholder(store, connection: healthy) == nil)
  }

  @Test("Recall reads the user's non-empty messages, oldest first")
  func prompts() async throws {
    let store = try await Fixtures.store(
      rows: [
        Fixtures.userRow("a", text: "first"),
        Fixtures.userRow("b", text: "answer", role: .assistant),
        Fixtures.userRow("c", text: ""), Fixtures.userRow("d", text: "second"),
        Fixtures.userRow("d2", text: "second"),
      ])
    #expect(ComposerAdapter.prompts(store) == ["first", "second", "second"])
    #expect(ComposerAdapter.recall(nil) == nil)
    #expect(ComposerAdapter.recall { [] }?() == nil)
    #expect(ComposerAdapter.recall { ["a", "b"] }?() == "b")
  }

  @Test("An approval menu naming nothing it offers still maps; each risk keeps its name")
  func approvalMenuOddities() {
    let menu = ApprovalModeMenu(harness: "", options: [], selected: "exploded", next: "exploded")
    let modes = ComposerAdapter.approvalModes(menu)
    #expect(modes.options.isEmpty)
    #expect(modes.selected == nil)
    #expect(modes.next == nil)
    #expect(modes.title == " approvals")

    #expect(ComposerAdapter.risk(.readOnly) == .readOnly)
    #expect(ComposerAdapter.risk(.ask) == .ask)
    #expect(ComposerAdapter.risk(.autoEdit) == .autoEdit)
    #expect(ComposerAdapter.risk(.autoApprove) == .autoApprove)
    #expect(ComposerAdapter.risk(.fullAccess) == .fullAccess)
  }

  @Test("The whole state builds from a session with nothing filled in")
  func emptyState() async throws {
    let state = ComposerAdapter.state(
      try await Fixtures.store(hydrated: false), isStopping: true, dismissedError: nil,
      submitWithCommandReturn: true)
    #expect(state.isStopping)
    #expect(state.submitWithCommandReturn)
    #expect(state.configuration == nil)
    #expect(state.approvalModes == nil)
    #expect(state.queue.isEmpty)
    #expect(state.attachments.isEmpty)
    #expect(state.tray == nil)
    #expect(!state.isRunning)
  }

  @Test("The tray's gauge comes from the usage section")
  func trayUsage() async throws {
    let store = try await Fixtures.store(
      sections: [
        Fixtures.section(
          "usage", details: [("context_tokens", "100"), ("context_window", "400")])
      ])
    let state = ComposerAdapter.state(store, isStopping: false, dismissedError: nil)
    #expect(state.tray?.contextFraction == 0.25)
    #expect(state.tray?.contextTokens == ContextTokens(used: 100, window: 400))
  }
}
