import SwiftUI

/// Reply quotes and queued files: the quote blocks in both composers, a queue whose messages
/// carry files and `@` paths, a sent reply in both transcript styles, and Smart Routing on the
/// new-session composer.
enum ReplyQueueCatalog {
  static var entries: [CatalogEntry] {
    [
      .component(
        .composer, "reply-quotes", "Reply Quotes and Queued Files",
        summary: "Quoted transcript text as blocks, and queued messages with their files.",
        systemImage: "text.quote", canvas: .column(width: 760),
        keywords: ["reply", "quote", "queue", "attachments", "smart routing"],
        states: [
          CatalogState("composer", "Quotes in the composer") {
            CatalogStack {
              ComposerView(
                draft: .constant("Which one should go first?"), state: quoting,
                actions: quoteActions)
            }
          },
          CatalogState("cli-composer", "Quotes in the CLI prompt") { context in
            AnyView(
              CLIComposer(
                draft: .constant("Which one should go first?"), state: quoting,
                actions: quoteActions
              )
              .background { CLICanvas() }
              .cliPalette()
              .transcriptAppearance(TranscriptAppearance(style: .cli))
              .omnigentTheme(context.preferences.theme))
          },
          CatalogState("queue", "Queued with files") {
            CatalogStack {
              QueueStrip(
                queue: queuedWithFiles, isRunning: true, canSteer: true,
                actions: ComposerExtraActions())
            }
          },
          CatalogState("chat-sent", "Sent reply, chat") {
            TranscriptView(state: sentReply, actions: GalleryActions.conversation)
              .frame(height: 420)
          },
          CatalogState("cli-sent", "Sent reply, CLI") { context in
            AnyView(
              TranscriptView(state: sentReply)
                .transcriptAppearance(TranscriptAppearance(style: .cli))
                .omnigentTheme(context.preferences.theme)
                .frame(height: 420))
          },
          CatalogState("new-session-routing", "New session, Smart Routing on") {
            CatalogStack {
              ComposerView(
                draft: .constant(""), state: routedStart, actions: GalleryActions.composer)
            }
          },
        ])
    ]
  }

  private static let answer = """
    Two questions are open:
    1. Should refresh retry after sleep?
    2. Who owns the token cache?
    """

  private static var quoteActions: ComposerActions {
    var actions = GalleryActions.composer
    actions.extras.quotes = ComposerQuoteActions(remove: { _ in }, editLead: { _, _ in })
    return actions
  }

  private static var quoting: ComposerViewState {
    var state = PreviewData.idleSessionComposer
    state.quotes = [
      ComposerQuote(text: "Should refresh retry after sleep?"),
      ComposerQuote(before: "And this one:", text: "Who owns the token cache?"),
    ]
    return state
  }

  private static var queuedWithFiles: [QueuedMessage] {
    [
      QueuedMessage(
        id: "q-files", text: "And this screenshot",
        files: [
          QueuedMessage.File(name: "refresh-after-sleep.png", isImage: true),
          QueuedMessage.File(name: "trace.json", isImage: false),
        ]),
      QueuedMessage(
        id: "q-paths", text: "", mentions: ["client-core/src/auth/refresh.rs", "docs/"]),
    ]
  }

  private static var sentReply: ConversationViewState {
    var state = ConversationViewState(header: SessionHeader(id: "reply", title: "Reply"))
    state.rows = [
      Row(id: "u1", role: .user, text: "Summarize the open questions"),
      Row(id: "a1", role: .assistant, text: answer, responseId: "r1"),
      Row(
        id: "u2", role: .user,
        text: "> Should refresh retry after sleep?\n\nYes, once. Which one should go first?"),
    ]
    state.revision = 1
    return state
  }

  private static var routedStart: ComposerViewState {
    var state = PreviewData.startComposer
    state.configuration?.harness = "codex-native"
    state.configuration?.smartRouting = .enabled
    return state
  }
}
