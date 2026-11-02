import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("Type ramp and transcript rhythm")
struct TypeRampTests {
  nonisolated static let bodies: [CGFloat] = [12, 13, 15, 17, 19, 24, 31]

  @Test("headings step down to the body size, never below it", arguments: bodies)
  func headings(body: CGFloat) {
    let ramp = TypeRamp(body: body)
    let sizes = (1...4).map(ramp.heading)
    #expect(sizes == sizes.sorted(by: >), "\(sizes)")
    #expect(sizes.last == body)
    #expect(ramp.heading(6) == body, "deeper levels use H4")
    #expect(sizes.first ?? 0 >= body * 1.35)
  }

  @Test("code reads smaller than prose", arguments: bodies)
  func code(body: CGFloat) {
    let ramp = TypeRamp(body: body)
    #expect(ramp.code < body)
    #expect(ramp.code >= body * 0.8)
  }

  @Test("line heights and gaps sit on the 4 pt grid", arguments: bodies)
  func grid(body: CGFloat) {
    let ramp = TypeRamp(body: body)
    let lines = [ramp.bodyLineHeight, ramp.codeLineHeight] + (1...4).map(ramp.headingLineHeight)
    let gaps = [
      TypeRamp.paragraphSpacing, TypeRamp.listSpacing, TypeRamp.headingAbove,
      TypeRamp.headingBelow,
    ]
    for value in lines + gaps {
      #expect(value.truncatingRemainder(dividingBy: TypeRamp.grid) == 0, "\(value)")
    }
    #expect(ramp.bodyLineHeight > body)
    #expect((1...4).allSatisfy { ramp.headingLineHeight($0) >= ramp.heading($0) })
  }

  @Test("the platform default keeps today's body size and line height")
  func platformDefault() {
    let ramp = TypeRamp(body: TypeRamp.defaultBody)
    #if os(macOS)
      #expect(ramp.body == 15)
      #expect(ramp.bodyLineHeight == 24)
      #expect((1...4).map(ramp.heading) == [21, 19, 16.5, 15])
      #expect(ramp.code == 13)
    #else
      #expect(ramp.body == 17)
      #expect(ramp.bodyLineHeight == 24)
      #expect(ramp.code == 15)
    #endif
  }

  @Test("a heading has more space above it than below it")
  func headingRhythm() {
    let paragraph = MarkdownBlock.paragraph(AttributedString("Text"))
    let heading = MarkdownBlock.heading(level: 3, text: AttributedString("Title"))
    #expect(TypeRamp.spacing(above: heading, after: nil) == 0)
    #expect(TypeRamp.spacing(above: heading, after: paragraph) == TypeRamp.headingAbove)
    #expect(TypeRamp.spacing(above: paragraph, after: heading) == TypeRamp.headingBelow)
    #expect(TypeRamp.spacing(above: paragraph, after: paragraph) == TypeRamp.paragraphSpacing)
    #expect(TypeRamp.headingAbove > TypeRamp.headingBelow)
  }

  @Test("inline code takes the code size, keeping bold")
  func inlineCode() {
    var text = AttributedString("Run ")
    var code = AttributedString("make")
    code.inlinePresentationIntent = .code
    var bold = AttributedString("all")
    bold.inlinePresentationIntent = [.code, .stronglyEmphasized]
    text.append(code)
    text.append(bold)
    let sized = TypeRamp(body: 15).sizingCode(in: text, size: 13)
    let fonts = sized.runs.map { $0.swiftUI.font }
    #expect(fonts[0] == nil, "prose keeps the environment font")
    #expect(fonts[1] == .system(size: 13, weight: .regular, design: .monospaced))
    #expect(fonts[2] == .system(size: 13, weight: .semibold, design: .monospaced))
  }

  // MARK: Chat text size

  private func scratchDefaults() throws -> UserDefaults {
    let name = "type-ramp-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("the chat text size persists, reaches the appearance and is clamped")
  func chatFontSize() throws {
    let defaults = try scratchDefaults()
    let preferences = TranscriptPreferences(defaults: defaults)
    #expect(preferences.chatFontSize == TranscriptAppearance.defaultChatFontSize)
    preferences.chatFontSize = 19
    let reloaded = TranscriptPreferences(defaults: defaults)
    #expect(reloaded.chatFontSize == 19)
    #expect(reloaded.appearance().chatFontSize == 19)
    #expect(
      TranscriptAppearance(chatFontSize: 2).chatFontSize
        == TranscriptAppearance.chatFontSizes.lowerBound)
    #expect(
      TranscriptAppearance(chatFontSize: 80).chatFontSize
        == TranscriptAppearance.chatFontSizes.upperBound)
  }

  @Test("a malformed chat text size falls back and is reported")
  func malformedChatFontSize() throws {
    let defaults = try scratchDefaults()
    defaults.set("large", forKey: TranscriptPreferences.chatFontSizeKey)
    let preferences = TranscriptPreferences(defaults: defaults)
    #expect(preferences.chatFontSize == TranscriptAppearance.defaultChatFontSize)
    #expect(
      preferences.readErrors.map(\.description)
        == [ThemePreferences.ReadError.malformed(key: TranscriptPreferences.chatFontSizeKey)]
        .map(\.description))
  }
}

#if os(macOS)
  /// Measured layout: the rendered prose rhythm and the Mac action row's footprint.
  @Suite("Transcript rhythm, rendered", .serialized)
  @MainActor
  struct TranscriptRhythmRenderTests {
    /// The rendered height of `view` at `width`, in points.
    static func height(_ view: some View, width: CGFloat = 600) throws -> CGFloat {
      let rendered = try RenderSupport.render(
        view, width: width, scheme: .light, layout: .regular)
      let scale = CGFloat(rendered.image.pixelsWide) / width
      return CGFloat(rendered.image.pixelsHigh) / scale
    }

    @Test("prose lines are the ramp's line height apart")
    func proseLineHeight() throws {
      let ramp = TypeRamp(body: TypeRamp.defaultBody)
      let one = try Self.height(
        MarkdownView("One line").fixedSize(horizontal: false, vertical: true))
      let three = try Self.height(
        MarkdownView("One  \nTwo  \nThree").fixedSize(horizontal: false, vertical: true))
      #expect(abs((three - one) - 2 * ramp.bodyLineHeight) < 1, "\(one) \(three)")
    }

    @Test("hidden Mac actions reserve no lane under an answer or a question")
    func noReservedLane() throws {
      let actions = ConversationActions(forkFrom: { _ in })
      for role in [RowRole.assistant, .user] {
        let row = Row(id: "m1", role: role, text: "Done.", responseId: "resp_1")
        let message = try Self.height(
          MessageRowView(row: row, decoration: MessageDecoration())
            .environment(\.conversationActions, actions))
        let pinned = try Self.height(
          MessageRowView(row: row, decoration: MessageDecoration(showsActions: true))
            .environment(\.conversationActions, actions))
        // The row hangs into the transcript's gap: showing it changes nothing in the layout.
        #expect(message == pinned, "\(role): \(message) vs \(pinned)")
        // The gap to the next message: the message's spacing plus the row gap, at most 32 pt.
        let spacing = role == .user ? Theme.Spacing.extraSmall : Theme.Spacing.small
        #expect(spacing + Theme.Spacing.row <= 32)
      }
    }

    @Test("an answer, with or without its footer, sits at most 32 pt above the next question")
    func answerToQuestion() throws {
      let actions = ConversationActions(forkFrom: { _ in })
      let answer = Row(id: "a1", role: .assistant, text: "Done.", responseId: "resp_1")
      let question = Row(id: "u1", role: .user, text: "Thanks", responseId: "turn_2")
      let questionOnly = try Self.height(
        MessageRowView(row: question, decoration: MessageDecoration()))
      let text = try Self.height(MarkdownView("Done."))
      let footer = try Self.height(WorkedForLabel(duration: 3, finished: nil))
      for workedFor in [nil, 3] as [TimeInterval?] {
        let decoration = MessageDecoration(showsActions: true, workedFor: workedFor)
        let pair = try Self.height(
          VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            MessageRowView(row: answer, decoration: decoration)
            MessageRowView(row: question, decoration: MessageDecoration())
          }
          .environment(\.conversationActions, actions))
        // The answer's last visible line: its text, or the footer under it.
        let visible = workedFor == nil ? text : text + Theme.Spacing.small + footer
        let gap = pair - questionOnly - visible
        #expect(gap <= 32.5, "footer \(workedFor != nil): answer to question \(gap) pt")
      }
    }
  }
#endif
