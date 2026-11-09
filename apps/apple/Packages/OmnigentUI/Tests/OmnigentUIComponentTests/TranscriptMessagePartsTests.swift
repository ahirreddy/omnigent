#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Transcript attachments and prompts", .serialized)
  @MainActor
  struct TranscriptMessagePartsTests {
    init() {
      SystemSideEffects.reset()
    }

    private var copied: String? { SystemSideEffects.pasteboard.string(forType: .string) }

    private func message(_ row: Row) -> OffscreenWindow<AnyView> {
      transcriptScreen(MessageRowView(row: row, decoration: MessageDecoration()))
    }

    @Test("An attachment chip opens through the host, and says what it is")
    func attachmentChip() throws {
      var opened: [String] = []
      var actions = ConversationActions()
      actions.openAttachment = { opened.append($0.id) }
      let attachment = Attachment(
        id: "f", kind: .file, title: "notes.pdf", reference: "file-1", mimeType: "application/pdf")
      let view = transcriptScreen(AttachmentStrip(attachments: [attachment]), actions: actions)
      defer { view.close() }
      #expect(try view.shows("notes.pdf"))
      #expect(try view.shows("application/pdf"))
      try view.clickControl(at: 0)
      #expect(opened == ["f"])

      let menu = try #require(try view.contextMenu(at: center(view.controlFrames[0])))
      try view.choose("Copy Reference", in: menu)
      #expect(copied == "file-1")
    }

    @Test("A chip without bytes to open doesn't open")
    func attachmentChipDisabled() throws {
      var opened = 0
      var actions = ConversationActions()
      actions.openAttachment = { _ in opened += 1 }
      let view = transcriptScreen(
        AttachmentStrip(attachments: [Attachment(id: "f", kind: .video, title: "clip")]),
        actions: actions)
      defer { view.close() }
      #expect(try view.shows("Video"))
      try view.click(CGPoint(x: 40, y: 15))
      #expect(opened == 0)
    }

    @Test("Each attachment kind and an embedded one labels itself")
    func attachmentKinds() throws {
      let attachments = [
        Attachment(id: "a", kind: .audio, title: "a"),
        Attachment(id: "b", kind: .image, title: "b", isEmbedded: true),
      ]
      let view = transcriptScreen(AttachmentStrip(attachments: attachments))
      defer { view.close() }
      #expect(try view.shows("Audio"))
      #expect(try view.shows("Embedded, not kept"))
      let none = transcriptScreen(AttachmentStrip(attachments: []))
      defer { none.close() }
      #expect(none.controlFrames.isEmpty)
    }

    @Test("An uploaded image previews inline, and falls back to its chip if it can't be read")
    func attachmentPreview() async throws {
      let attachment = Attachment(id: "i", kind: .image, title: "shot.png", reference: "file-2")
      struct Unreadable: Error {}
      let previews = AttachmentPreviews { _ in throw Unreadable() }
      let view = transcriptScreen(
        AttachmentStrip(attachments: [attachment]).environment(\.attachmentPreviews, previews))
      defer { view.close() }
      try await letTasksRun(view)
      #expect(try view.shows("shot.png"))
    }

    @Test("Content this app can't show is one quiet line, opening to any safe text")
    func unsupported() throws {
      #expect(UnsupportedContentView.title("  ") == "Content this app can\u{2019}t show")
      #expect(
        UnsupportedContentView.title("message CONTENT") == "Content this app can\u{2019}t show")
      #expect(UnsupportedContentView.title("Audio") == "Audio \u{00B7} not shown in this app")

      let details = [DetailSection(id: "d", title: "Raw", text: "Inner text")]
      let row = Row(
        id: "m", role: .assistant, text: "Hi",
        activity: Activity(kind: .unknown, title: "Audio", details: details))
      let view = message(row)
      defer { view.close() }
      #expect(try view.shows("Audio \u{00B7} not shown in this app"))
      #expect(try !view.shows("Inner text"))
      let frame = try #require(view.controlFrames.last)
      try view.click(center(frame))
      #expect(try view.shows("Inner text"))
    }

    @Test("A user message collapses past the limit, expands and collapses again")
    func longPrompt() throws {
      let text = String(repeating: "a", count: UserPrompt.collapseThreshold + 5)
      // Tall enough that the button under the prompt stays in the window.
      let view = transcriptScreen(UserPromptBody(text: text), height: 4_000)
      defer { view.close() }
      let expand = UserPrompt.expandTitle(text)
      #expect(try view.shows(expand))
      try view.clickControl(at: 0)
      #expect(try view.shows("Collapse prompt"))
      try view.clickControl(at: 0)
      #expect(try view.shows(expand))
    }

    @Test("Attachment markers become chips, and uploads drop out without one")
    func mentions() throws {
      let view = transcriptScreen(
        UserPromptBody(
          text: "[Attached: src/app.ts]\n[Attached file: docs/]\n[Attached: /tmp/up.png]\nHi"))
      defer { view.close() }
      #expect(try view.shows("src/app.ts"))
      #expect(try view.shows("docs"))
      #expect(try !view.shows("/tmp/up.png"))
      #expect(try view.shows("Hi"))
    }

    @Test("Chips wrap to the next line only when the width runs out")
    func flowLayout() throws {
      func chips(in width: CGFloat) -> (FrameLog, OffscreenWindow<AnyView>) {
        let log = FrameLog()
        let screen = transcriptScreen(
          FlowLayout(spacing: 6) {
            ForEach(0..<4, id: \.self) { index in
              Color.gray.frame(width: 80, height: 20).recordingFrame("chip\(index)", in: log)
            }
          },
          width: width, height: 300)
        return (log, screen)
      }
      let (wideLog, wide) = chips(in: 500)
      defer { wide.close() }
      #expect(wideLog.frames["chip0"]?.minY == wideLog.frames["chip3"]?.minY)
      #expect(wideLog.frames["chip1"]?.minX == 86)

      let (narrowLog, narrow) = chips(in: 180)
      defer { narrow.close() }
      #expect(narrowLog.frames["chip0"]?.minY == narrowLog.frames["chip1"]?.minY)
      #expect(narrowLog.frames["chip2"]?.minY == 26)
      #expect(narrowLog.frames["chip2"]?.minX == 0)
    }

    private func center(_ frame: CGRect) -> CGPoint {
      CGPoint(x: frame.midX, y: frame.midY)
    }
  }
#endif
