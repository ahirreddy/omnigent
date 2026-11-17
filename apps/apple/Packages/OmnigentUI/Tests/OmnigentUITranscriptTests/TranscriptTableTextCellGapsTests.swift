#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// What a text cell draws beside a settled message's text, as the SwiftUI row does: linked
  /// workspace paths, attachments, mentions and collapsed prompts.
  @Suite("Transcript table text cell gaps", .serialized)
  @MainActor
  struct TranscriptTableTextCellGapsTests {
    private typealias Fixture = TranscriptFixture

    init() {
      SystemSideEffects.reset()
    }

    private static let attachment = Attachment(
      id: "f1", kind: .file, title: "notes.txt", reference: "file-1", mimeType: "text/plain")

    /// The links the cell's text runs hold.
    private func linkedURLs(in cell: TranscriptTableTextCell) -> [URL] {
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
      let screen = try await textTableScreen([
        Fixture.answer("a-cite", "See `src/a.ts` for the fix.", responseID: "r1")
      ]) { $0.workspaceFileLinks = links }
      defer { screen.close() }
      let cell = try textCell("a-cite", in: screen)
      #expect(try await waitUntil(screen) { !self.linkedURLs(in: cell).isEmpty })
      #expect(listed == ["src"], "the cited file's folder is listed once")
      let url = try #require(linkedURLs(in: cell).first)
      let open = try #require(openURL(of: cell))
      open(url)
      #expect(opened == [WorkspaceFileTarget(path: "src/a.ts")])
    }

    @Test("A cited path its folder doesn't hold stays plain text in the text cell")
    func missingPathStaysText() async throws {
      let links = WorkspaceFileLinks(
        root: { "/home/u/ws" }, home: { "/home/u" },
        listFolder: { _ in WorkspaceFolderListing(files: ["other.ts"]) }, open: { _ in })
      let screen = try await textTableScreen([
        Fixture.answer("a-missing", "See `src/a.ts` for the fix.", responseID: "r1")
      ]) { $0.workspaceFileLinks = links }
      defer { screen.close() }
      let controller = try tableController(of: screen)
      let index = try #require(controller.model.index(of: "a-missing"))
      #expect(controller.cellKind(at: index) == .text(.answer))
      try await letTasksRun(screen, milliseconds: 200)
      #expect(linkedURLs(in: try textCell("a-missing", in: screen)).isEmpty)
    }

    // MARK: Attachments

    @Test("A message's attachments sit where SwiftUI's row puts them, as tall as that row")
    func attachmentsMatchSwiftUI() throws {
      let environment = textCellEnvironment()
      let attached = [Self.attachment]
      let prompt = try shownMatchingSwiftUI(
        textCellRow(Row(id: "u-att", role: .user, text: "With a file", attachments: attached)),
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
        let cell = try shownMatchingSwiftUI(textCellRow(alone), environment)
        #expect(cell.runs.isEmpty && cell.accessoryViews.count == 1, "\(alone.id)")
      }
      // An answer's follow its text.
      let answer = try shownMatchingSwiftUI(
        textCellRow(
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
      let screen = try await textTableScreen(
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
      let environment = textCellEnvironment()
      let mentioned = "[Attached: src/app.swift]\n[Attached: docs/]\nWhat do these do?"
      let cell = try shownMatchingSwiftUI(
        textCellRow(Row(id: "u-mention", role: .user, text: mentioned)), environment)
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
        textCellRow(Row(id: "u-mention-only", role: .user, text: "[Attached: src/app.swift]")),
        environment)
      #expect(alone.runs.isEmpty && alone.accessoryViews.count == 1)
      let both = try shownMatchingSwiftUI(
        textCellRow(
          Row(
            id: "u-mention-file", role: .user, text: mentioned, attachments: [Self.attachment])),
        environment)
      #expect(both.accessoryViews.count == 2)
      #expect(both.accessoryViews.first?.accessory == .attachments([Self.attachment]))
    }

    // MARK: Collapsed prompts

    private static let longPrompt = String(repeating: "A long prompt line. ", count: 700)

    @Test("A long prompt starts collapsed with Show full prompt, as tall as SwiftUI's row")
    func collapsedPromptMatchesSwiftUI() throws {
      let environment = textCellEnvironment()
      let prompt = textCellRow(Row(id: "u-long", role: .user, text: Self.longPrompt))
      let cell = try shownMatchingSwiftUI(prompt, environment)
      #expect(cell.message?.promptFold == .collapsed)
      #expect(cell.message?.markdown.hasSuffix("\u{2026}") == true)
      #expect(
        cell.accessoryViews.last?.accessory
          == .promptToggle(title: UserPrompt.expandTitle(Self.longPrompt), collapses: false))
      // Shown whole, it says Collapse prompt and measures as it shows.
      let folds = TranscriptTableFolds()
      folds.setExpanded(true, for: "u-long")
      let style = textCellStyle(environment)
      let expanded = TranscriptTableTextCell(style: style, folds: folds)
      expanded.show(prompt, version: 0, width: textCellWidth)
      #expect(expanded.message?.promptFold == .expanded)
      #expect(expanded.message?.markdown == Self.longPrompt)
      #expect(
        expanded.accessoryViews.last?.accessory
          == .promptToggle(title: UserPrompt.collapseTitle, collapses: true))
      #expect(expanded.idealHeight > cell.idealHeight)
      let message = try #require(expanded.message)
      #expect(try farRowHeight(message, style) == expanded.idealHeight)
    }

    @Test("Show full prompt expands the prompt in its text cell, and Collapse folds it again")
    func collapsedPromptToggles() async throws {
      let screen = try await textTableScreen([
        Row(id: "u-long", role: .user, text: Self.longPrompt)
      ])
      defer { screen.close() }
      let controller = try tableController(of: screen)
      let index = try #require(controller.model.index(of: "u-long"))
      let collapsed = try textCell("u-long", in: screen)
      let collapsedHeight = collapsed.idealHeight
      let expand = try #require(collapsed.accessoryViews.last)
      try scrollToShow(expand, in: screen)
      try await letTasksRun(screen)
      try screen.click(expand)
      #expect(
        try await waitUntil(screen) {
          try textCell("u-long", in: screen).message?.promptFold == .expanded
        })
      #expect(controller.folds.isExpanded("u-long", isLive: false), "the choice outlasts the cell")
      let expanded = try textCell("u-long", in: screen)
      #expect(expanded.idealHeight > collapsedHeight)
      #expect(
        try await waitUntil(screen) { controller.model.height(at: index) == expanded.idealHeight })
      let collapse = try #require(expanded.accessoryViews.last)
      #expect(
        collapse.accessory == .promptToggle(title: UserPrompt.collapseTitle, collapses: true))
      try scrollToShow(collapse, in: screen)
      try await letTasksRun(screen)
      try screen.click(collapse)
      #expect(
        try await waitUntil(screen) {
          try textCell("u-long", in: screen).message?.promptFold == .collapsed
        })
      #expect(
        try await waitUntil(screen) { controller.model.height(at: index) == collapsedHeight })
    }

    // MARK: Interrupted

    @Test("An interrupted message says so where SwiftUI's row does, as tall as that row")
    func interruptedMatchesSwiftUI() async throws {
      let environment = textCellEnvironment()
      let promptRow = Row(id: "u-cut", role: .user, text: "Cut off", interrupted: true)
      let answerRow = Row(
        id: "a-cut", role: .assistant, text: "Cut off too", responseId: "r1", interrupted: true)
      // Under a prompt's bubble, at its trailing edge.
      let prompt = try shownMatchingSwiftUI(textCellRow(promptRow), environment)
      let line = try #require(prompt.accessoryViews.last)
      #expect(line.accessory == .interrupted)
      let bubble = try #require(prompt.subviews.first { $0 is TranscriptTableBubbleView })
      #expect(abs(line.frame.minY - (bubble.frame.maxY + Theme.Spacing.extraSmall)) < 0.5)
      #expect(abs(line.frame.maxX - bubble.frame.maxX) < 0.5)
      // Under an answer's text, after its attachments.
      var attached = answerRow
      attached.attachments = [Self.attachment]
      let answer = try shownMatchingSwiftUI(textCellRow(attached), environment)
      #expect(
        answer.accessoryViews.map(\.accessory) == [.attachments([Self.attachment]), .interrupted])
      // Both read as SwiftUI's line does.
      let screen = try await textTableScreen([promptRow, answerRow])
      defer { screen.close() }
      for id in ["u-cut", "a-cut"] {
        let cell = try textCell(id, in: screen)
        let shown = try #require(cell.accessoryViews.last)
        #expect(try screen.shownText(under: shown) == ["Interrupted"], "\(id)")
      }
    }
  }
#endif
