#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
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

    /// A chat environment with the TextKit renderer, which the test adds to.
    private func environment(_ transform: (inout EnvironmentValues) -> Void = { _ in })
      -> TranscriptTableEnvironment
    {
      let environment = TranscriptTableEnvironment()
      var values = EnvironmentValues()
      values.messageTextRenderer = .textKit
      transform(&values)
      environment.values = values
      return environment
    }

    private func style(_ environment: TranscriptTableEnvironment) -> TranscriptTableTextStyle {
      let style = TranscriptTableTextStyle(environment: environment)
      style.refresh()
      return style
    }

    private func row(_ message: Row, decoration: MessageDecoration = MessageDecoration())
      -> TranscriptTableRow
    {
      TranscriptTableRow(
        .segment(
          SegmentEntry(
            segment: .item(.message(message)), decorations: [message.id: decoration],
            duration: nil)))
    }

    /// The height SwiftUI's row gives `row` in a hosted cell.
    private func hostedHeight(_ row: TranscriptTableRow, _ environment: TranscriptTableEnvironment)
      -> CGFloat
    {
      let cell = TranscriptTableHostingCell.make(environment: environment)
      cell.show(row, version: 0, width: Self.width)
      return cell.idealHeight
    }

    /// `row`'s height far from view, from its runs' and parts' sizes.
    private func measuredHeight(_ row: TranscriptTableRow, _ style: TranscriptTableTextStyle)
      throws -> CGFloat
    {
      let message = try #require(TranscriptTableTextMessage.make(row, ramp: style.ramp))
      return try #require(
        TranscriptTableTextCell.measuredHeight(
          of: message, style: style, width: Self.width,
          blockHeight: { block, piece, width in
            let view = TranscriptTableBlockView.make(environment: style.environment)
            view.show(block, piece: piece, width: width)
            return view.idealHeight
          }))
    }

    /// Shows `row` in a new text cell, which must take it, and checks it is as tall as SwiftUI's
    /// row and as a far row measures.
    private func shownMatchingSwiftUI(
      _ row: TranscriptTableRow, _ environment: TranscriptTableEnvironment,
      sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> TranscriptTableTextCell {
      let style = style(environment)
      let cell = TranscriptTableTextCell(style: style)
      cell.show(row, version: 0, width: Self.width)
      #expect(cell.message != nil, "\(row.id) takes a text cell", sourceLocation: sourceLocation)
      #expect(
        cell.idealHeight == hostedHeight(row, environment), "\(row.id) is as tall as SwiftUI's",
        sourceLocation: sourceLocation)
      #expect(
        try measuredHeight(row, style) == cell.idealHeight, "\(row.id) measures as it shows",
        sourceLocation: sourceLocation)
      return cell
    }

    private static let attachment = Attachment(
      id: "f1", kind: .file, title: "notes.txt", reference: "file-1", mimeType: "text/plain")

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

    // MARK: Attachments

    @Test("A message's attachments sit where SwiftUI's row puts them, as tall as that row")
    func attachmentsMatchSwiftUI() throws {
      let environment = environment()
      let attached = [Self.attachment]
      let prompt = try shownMatchingSwiftUI(
        row(Row(id: "u-att", role: .user, text: "With a file", attachments: attached)),
        environment)
      // They lead the bubble, above the text.
      let strip = try #require(prompt.accessoryViews.first)
      let text = try #require(prompt.runs.first?.view)
      let bubble = try #require(prompt.subviews.first { $0 is TranscriptTableBubbleView })
      #expect(strip.frame.maxY + Theme.Spacing.small <= text.frame.minY + 0.5)
      #expect(bubble.frame.contains(strip.frame) && bubble.frame.contains(text.frame))
      // Attachments alone, or behind upload markers only, fill the bubble with no text.
      for alone in [
        Row(id: "u-only", role: .user, attachments: attached),
        Row(id: "u-upload", role: .user, text: "[Attached: /tmp/notes.txt]", attachments: attached),
      ] {
        let cell = try shownMatchingSwiftUI(row(alone), environment)
        #expect(cell.runs.isEmpty && cell.accessoryViews.count == 1, "\(alone.id)")
      }
      // An answer's follow its text.
      let answer = try shownMatchingSwiftUI(
        row(
          Row(
            id: "a-att", role: .assistant, text: "Here it is.", attachments: attached,
            responseId: "r1")), environment)
      let answerText = try #require(answer.runs.first?.view)
      let answerStrip = try #require(answer.accessoryViews.first)
      #expect(answerText.frame.maxY + Theme.Spacing.small <= answerStrip.frame.minY + 0.5)
    }

    @Test("An attachment chip in a text cell opens through the host")
    func attachmentOpens() async throws {
      var opened: [String] = []
      var actions = ConversationActions()
      actions.openAttachment = { opened.append($0.id) }
      let screen = try await tableScreen(
        [Row(id: "u-att", role: .user, text: "With a file", attachments: [Self.attachment])],
        actions: actions)
      defer { screen.close() }
      let cell = try textCell("u-att", in: screen)
      let strip = try #require(cell.accessoryViews.first)
      #expect(try screen.shownText(under: strip).contains("notes.txt"))
      try screen.click(strip)
      #expect(opened == ["f1"])
    }

    // MARK: Mentions

    @Test("A prompt's mentions are chips above its text, as tall as SwiftUI's row")
    func mentionsMatchSwiftUI() throws {
      let environment = environment()
      let mentioned = "[Attached: src/app.swift]\n[Attached: docs/]\nWhat do these do?"
      let cell = try shownMatchingSwiftUI(
        row(Row(id: "u-mention", role: .user, text: mentioned)), environment)
      let chips = try #require(cell.accessoryViews.first)
      #expect(
        chips.accessory
          == .mentions([
            UserPrompt.Mention(path: "src/app.swift", isFolder: false),
            UserPrompt.Mention(path: "docs", isFolder: true),
          ]))
      let text = try #require(cell.runs.first?.view)
      #expect(chips.frame.maxY + Theme.Spacing.small <= text.frame.minY + 0.5)
      #expect(cell.message?.markdown == "What do these do?", "the markers leave the text")
      // Mentions alone, and after attachments.
      let alone = try shownMatchingSwiftUI(
        row(Row(id: "u-mention-only", role: .user, text: "[Attached: src/app.swift]")),
        environment)
      #expect(alone.runs.isEmpty && alone.accessoryViews.count == 1)
      let both = try shownMatchingSwiftUI(
        row(
          Row(
            id: "u-mention-file", role: .user, text: mentioned, attachments: [Self.attachment])),
        environment)
      #expect(both.accessoryViews.map(\.accessory).count == 2)
      #expect(both.accessoryViews.first?.accessory == .attachments([Self.attachment]))
    }
  }
#endif
