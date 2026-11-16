#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// A conversation as the app mounts it, with the chat-wide drop over its transcript.
  private struct DropConversationHost: View {
    let composer: ComposerViewState
    let actions: ComposerActions
    @State private var draft = ""
    @State private var mode = SessionViewMode.chat
    @State private var showsInspector = false

    var body: some View {
      ConversationScreen(
        state: ConversationViewState(
          header: TranscriptFixture.header, rows: [TranscriptFixture.answer("a")]),
        composer: composer, draft: ComposerDraft($draft), showsInspector: $showsInspector,
        mode: $mode, actions: ConversationActions(), composerActions: actions
      ) {
        EmptyView()
      }
    }
  }

  /// Files and queued messages dropped on the composer and the chat. The drop goes to the view's
  /// own drop target with a scripted `NSDraggingInfo`; no system drag starts.
  @Suite("Composer: drops", .serialized)
  @MainActor
  struct ComposerGapsDropTests {
    private let log = ComposerActionLog()
    private static let file = URL(fileURLWithPath: "/tmp/dropped.txt")

    init() {
      SystemSideEffects.reset()
    }

    private func filePasteboard<Content>(_ screen: OffscreenWindow<Content>) -> NSPasteboard {
      screen.dragPasteboard { $0.setString(Self.file.absoluteString, forType: .fileURL) }
    }

    @Test("A file dropped on the composer attaches")
    func composerTakesFile() async throws {
      let screen = openComposer(ComposerScreenModel(state: ComposerViewState()), log.actions)
      defer { screen.close() }
      let point = try #require(screen.editorCenter)
      let drop = try screen.beginScriptedDrop(at: point, pasteboard: filePasteboard(screen))
      #expect(!drop.operation.isEmpty)
      #expect(screen.finishScriptedDrop(drop))
      #expect(try await screen.eventually { !log.attachments.isEmpty })
      #expect(log.attachments == [.file(url: Self.file)])
    }

    @Test("A composer that takes no attachments refuses the drop")
    func composerRefuses() throws {
      var actions = log.actions
      actions.addAttachments = nil
      let screen = openComposer(ComposerScreenModel(state: ComposerViewState()), actions)
      defer { screen.close() }
      let point = try #require(screen.editorCenter)
      let drop = try screen.beginScriptedDrop(at: point, pasteboard: filePasteboard(screen))
      #expect(drop.operation.isEmpty)
      #expect(log.attachments.isEmpty)
    }

    @Test("A file dropped on the CLI composer attaches")
    func cliComposerTakesFile() async throws {
      let screen = try cliComposerScreen(ComposerViewState(), actions: log.actions)
      defer { screen.close() }
      let point = try #require(screen.editorCenter)
      let drop = try screen.beginScriptedDrop(at: point, pasteboard: filePasteboard(screen))
      #expect(screen.finishScriptedDrop(drop))
      #expect(try await screen.eventually { !log.attachments.isEmpty })
      #expect(log.attachments == [.file(url: Self.file)])
    }

    // MARK: The whole chat

    private func chat(isEnabled: Bool = true) -> OffscreenWindow<some View> {
      let log = log
      let view = Color.gray
        .chatDropTarget(isEnabled: isEnabled) { log.attachments.append(contentsOf: $0) }
        .frame(width: 400, height: 300)
      return OffscreenWindow(view, width: 400, height: 300)
    }

    @Test("The outline shows while a drag hovers, and goes when it leaves")
    func outlineFollowsTheDrag() throws {
      let screen = chat()
      defer { screen.close() }
      #expect(try !screen.shows("Drop files here"))
      let center = CGPoint(x: 200, y: 150)
      let drop = try screen.beginScriptedDrop(at: center, pasteboard: filePasteboard(screen))
      #expect(try screen.shows("Drop files here"))
      screen.exitScriptedDrop(drop)
      #expect(try !screen.shows("Drop files here"))
      #expect(log.attachments.isEmpty)
    }

    @Test("A file dropped on the chat attaches, and the outline goes")
    func chatTakesFile() async throws {
      let screen = chat()
      defer { screen.close() }
      let center = CGPoint(x: 200, y: 150)
      let drop = try screen.beginScriptedDrop(at: center, pasteboard: filePasteboard(screen))
      #expect(screen.finishScriptedDrop(drop))
      #expect(try await screen.eventually { !log.attachments.isEmpty })
      #expect(log.attachments == [.file(url: Self.file)])
      #expect(try !screen.shows("Drop files here"))
    }

    @Test("A chat that can't attach now shows no outline and takes nothing")
    func chatRefuses() throws {
      let screen = chat(isEnabled: false)
      defer { screen.close() }
      let center = CGPoint(x: 200, y: 150)
      let drop = try screen.beginScriptedDrop(at: center, pasteboard: filePasteboard(screen))
      #expect(drop.operation.isEmpty)
      #expect(try !screen.shows("Drop files here"))
    }

    // MARK: The queue

    private func queue() -> OffscreenWindow<ComposerScreen> {
      var state = ComposerViewState()
      state.queue = [
        QueuedMessage(id: "one", text: "first"), QueuedMessage(id: "two", text: "second"),
      ]
      return openComposer(ComposerScreenModel(state: state), log.actions)
    }

    /// The queue's rows are the composer's short drop targets, top to bottom.
    private func queueRows(_ screen: OffscreenWindow<ComposerScreen>) -> [CGRect] {
      screen.allViews.filter { !$0.registeredDraggedTypes.isEmpty }
        .map { $0.convert($0.bounds, to: screen.host) }
        .filter { $0.height < 80 }
        .sorted { $0.minY < $1.minY }
    }

    @Test("A queued message dragged onto another moves there")
    func queueReorders() async throws {
      let screen = queue()
      defer { screen.close() }
      let rows = queueRows(screen)
      #expect(rows.count == 2)
      let target = try #require(rows.first)
      let pasteboard = screen.dragPasteboard { $0.setString("two", forType: .string) }
      let drop = try screen.beginScriptedDrop(
        at: CGPoint(x: target.midX, y: target.midY), pasteboard: pasteboard)
      #expect(screen.finishScriptedDrop(drop))
      #expect(try await screen.eventually { !log.events.isEmpty })
      #expect(log.events == ["move:[1]:0"])
    }

    @Test("Text that isn't a queued message moves nothing")
    func queueIgnoresOtherText() async throws {
      let screen = queue()
      defer { screen.close() }
      let target = try #require(queueRows(screen).first)
      let pasteboard = screen.dragPasteboard { $0.setString("not a message", forType: .string) }
      let drop = try screen.beginScriptedDrop(
        at: CGPoint(x: target.midX, y: target.midY), pasteboard: pasteboard)
      screen.finishScriptedDrop(drop)
      await screen.drainTasks()
      #expect(log.events.isEmpty)
    }

    @Test("Without a move action the drop is refused")
    func queueWithoutMove() async throws {
      var actions = log.actions
      actions.extras.moveQueued = nil
      var state = ComposerViewState()
      state.queue = [
        QueuedMessage(id: "one", text: "first"), QueuedMessage(id: "two", text: "second"),
      ]
      let screen = openComposer(ComposerScreenModel(state: state), actions)
      defer { screen.close() }
      let target = try #require(queueRows(screen).first)
      let pasteboard = screen.dragPasteboard { $0.setString("two", forType: .string) }
      let drop = try screen.beginScriptedDrop(
        at: CGPoint(x: target.midX, y: target.midY), pasteboard: pasteboard)
      screen.finishScriptedDrop(drop)
      await screen.drainTasks()
      #expect(log.events.isEmpty)
    }
  }

  // MARK: The conversation screen

  extension ComposerGapsDropTests {
    /// A point in the transcript, well above the composer.
    private static var transcript: CGPoint { CGPoint(x: 450, y: 150) }

    private func conversation(_ composer: ComposerViewState) -> OffscreenWindow<some View> {
      let screen = OffscreenWindow(
        DropConversationHost(composer: composer, actions: log.actions), width: 900, height: 600)
      screen.settle(0.3)
      return screen
    }

    @Test("A file dropped on a conversation's transcript attaches through its composer")
    func conversationTakesFile() async throws {
      let screen = conversation(ComposerViewState())
      defer { screen.close() }
      let drop = try screen.beginScriptedDrop(
        at: Self.transcript, pasteboard: filePasteboard(screen))
      #expect(!drop.operation.isEmpty)
      #expect(try screen.shows("Drop files here"))
      #expect(screen.finishScriptedDrop(drop))
      #expect(try await screen.eventually { !log.attachments.isEmpty })
      #expect(log.attachments == [.file(url: Self.file)])
      #expect(try !screen.shows("Drop files here"))
    }

    @Test("A conversation that can't send now takes no dropped file")
    func conversationRefusesFile() throws {
      let screen = conversation(
        ComposerViewState(availability: .unavailable(reason: "Host offline")))
      defer { screen.close() }
      let drop = try screen.beginScriptedDrop(
        at: Self.transcript, pasteboard: filePasteboard(screen))
      #expect(drop.operation.isEmpty)
      #expect(try !screen.shows("Drop files here"))
      #expect(log.attachments.isEmpty)
    }
  }
#endif
