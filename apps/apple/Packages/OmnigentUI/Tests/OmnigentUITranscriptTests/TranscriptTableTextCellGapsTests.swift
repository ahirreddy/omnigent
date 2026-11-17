#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// What a text cell draws beside a settled message's text, and what it offers, as the SwiftUI
  /// row does: linked workspace paths, attachments, mentions, collapsed prompts, the Interrupted
  /// line, shared-session avatars, the linked-message flash, the menu, focus and VoiceOver.
  @Suite("Transcript table text cell gaps", .serialized)
  @MainActor
  struct TranscriptTableTextCellGapsTests {
    private typealias Fixture = TranscriptFixture
    static let width: CGFloat = 900

    init() {
      SystemSideEffects.reset()
    }

    /// The table transcript with the TextKit renderer, in an environment the test adds to.
    private struct Host: View {
      let conversation: LiveConversation
      var actions = ConversationActions()
      var environment: (inout EnvironmentValues) -> Void = { _ in }

      var body: some View {
        TableTranscriptView(
          state: conversation.state, liveRows: nil, actions: actions,
          scrollToLatestRequest: conversation.scrollRequest
        )
        .environment(\.messageTextRenderer, .textKit)
        .transformEnvironment(\.self, transform: environment)
      }
    }

    /// The table transcript showing `rows`, opened.
    private func tableScreen(
      _ rows: [Row], actions: ConversationActions = ConversationActions(),
      environment: @escaping (inout EnvironmentValues) -> Void = { _ in }
    ) async throws -> OffscreenWindow<AnyView> {
      let conversation = LiveConversation(
        ConversationViewState(header: Fixture.header, rows: rows))
      let screen = transcriptScreen(
        Host(conversation: conversation, actions: actions, environment: environment),
        actions: actions, width: Self.width, height: 900)
      try await letTasksRun(screen, milliseconds: 200)
      return screen
    }

    private func controller(_ screen: OffscreenWindow<AnyView>) throws
      -> TranscriptTableController
    {
      let driver = TranscriptScrollDriver(screen: screen)
      let table = try #require(driver.scrollView?.documentView as? NSTableView)
      return try #require(table.delegate as? TranscriptTableController)
    }

    /// The text cell showing row `id`.
    private func textCell(_ id: String, in screen: OffscreenWindow<AnyView>) throws
      -> TranscriptTableTextCell
    {
      let controller = try controller(screen)
      let index = try #require(controller.model.index(of: id), "\(id) is a row")
      return try #require(
        controller.realizedCell(at: index) as? TranscriptTableTextCell, "\(id) is a text cell")
    }

    /// The links the cell's text runs hold.
    private func links(in cell: TranscriptTableTextCell) -> [URL] {
      cell.runs.compactMap(\.document).flatMap { MessageTextDocument.links(in: $0.text) }
        .map(\.url)
    }

    /// The action the cell's first text run opens links with.
    private func openURL(of cell: TranscriptTableTextCell) -> (@MainActor (URL) -> Void)? {
      switch cell.runs.first {
      case .live(let view): view.openURL
      case .raster(let view): view.openURL
      case .block, nil: nil
      }
    }

    // MARK: Linked paths

    @Test("A cited workspace file links once its folder's listing shows it, and opens in the app")
    func citedPathLinks() async throws {
      var listed: [String] = []
      var opened: [WorkspaceFileTarget] = []
      let links = WorkspaceFileLinks(
        root: { "/home/u/ws" }, home: { "/home/u" },
        listFolder: { folder in
          listed.append(folder)
          return WorkspaceFolderListing(files: ["a.ts"])
        },
        open: { opened.append($0) })
      let screen = try await tableScreen([
        Fixture.answer("a-cite", "See `src/a.ts` for the fix.", responseID: "r1")
      ]) { $0.workspaceFileLinks = links }
      defer { screen.close() }
      let cell = try textCell("a-cite", in: screen)
      #expect(try await waitUntil(screen) { !self.links(in: cell).isEmpty })
      #expect(listed == ["src"], "the cited file's folder is listed once")
      let url = try #require(links(in: cell).first)
      let open = try #require(openURL(of: cell))
      open(url)
      #expect(opened == [WorkspaceFileTarget(path: "src/a.ts")])
    }

    @Test("A cited path its folder doesn't hold stays plain text in the text cell")
    func missingPathStaysText() async throws {
      let links = WorkspaceFileLinks(
        root: { "/home/u/ws" }, home: { "/home/u" },
        listFolder: { _ in WorkspaceFolderListing(files: ["other.ts"]) }, open: { _ in })
      let screen = try await tableScreen([
        Fixture.answer("a-missing", "See `src/a.ts` for the fix.", responseID: "r1")
      ]) { $0.workspaceFileLinks = links }
      defer { screen.close() }
      let controller = try controller(screen)
      let index = try #require(controller.model.index(of: "a-missing"))
      #expect(controller.cellKind(at: index) == .text(.answer))
      try await letTasksRun(screen, milliseconds: 200)
      #expect(links(in: try textCell("a-missing", in: screen)).isEmpty)
    }
  }
#endif
