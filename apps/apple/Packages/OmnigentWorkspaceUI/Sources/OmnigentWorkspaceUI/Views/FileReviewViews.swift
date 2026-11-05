public import SwiftUI

/// What the file viewer offers for reviewing a file: its comments, leaving new ones, and
/// handing a span to the agent.
public struct FileReviewContext {
  /// The file's comments, open and sent.
  public var comments: [FileCommentLine]
  /// The viewer may leave, edit, resolve and send comments.
  public var canComment: Bool
  /// Leaves a comment.
  public var add: (String, FileTextSpan) async throws(WorkspaceFailure) -> Void
  /// Scrolls to and marks a line.
  public var reveal: (UInt64) -> Void
  /// Attaches a span to the agent's next message; `nil` hides it.
  public var attach: ((FileTextSpan) -> Void)?
  /// Quotes a span into the composer to ask about it; `nil` hides it.
  public var ask: ((FileTextSpan) -> Void)?
  // swiftlint:disable discouraged_optional_boolean
  /// Changes a comment's text (`body`) or state (`open`); `nil` hides Edit, Resolve, Reopen.
  public var update: ((FileCommentLine, String?, Bool?) async throws(WorkspaceFailure) -> Void)?
  // swiftlint:enable discouraged_optional_boolean
  /// Deletes a comment; `nil` hides Delete.
  public var delete: ((FileCommentLine) async throws(WorkspaceFailure) -> Void)?
  /// Sends the open comments to the agent ("Address All"); `nil` disables it.
  public var sendAll: (() async throws(WorkspaceFailure) -> Void)?

  /// A context.
  /// - Parameters:
  ///   - comments: The file's comments.
  ///   - canComment: The viewer may leave comments.
  ///   - add: Leaves a comment.
  ///   - reveal: Scrolls to a line.
  ///   - attach: Attaches a span to the agent.
  ///   - ask: Quotes a span into the composer.
  public init(
    comments: [FileCommentLine], canComment: Bool,
    add: @escaping (String, FileTextSpan) async throws(WorkspaceFailure) -> Void,
    reveal: @escaping (UInt64) -> Void, attach: ((FileTextSpan) -> Void)?,
    ask: ((FileTextSpan) -> Void)?
  ) {
    self.comments = comments
    self.canComment = canComment
    self.add = add
    self.reveal = reveal
    self.attach = attach
    self.ask = ask
  }

  /// The open comments, which the file marks.
  var openComments: [FileCommentLine] { comments.filter(\.isOpen) }

  /// The open comments by the line they start on.
  var commentsByLine: [UInt64: [FileCommentLine]] {
    Dictionary(grouping: openComments.filter { $0.line != nil }) { $0.line ?? 0 }
  }
}

extension FileTextSpan: Identifiable {
  /// The file and range.
  public var id: String { "\(path)#\(start)-\(end)" }
}

/// The review actions for a span: Comment, Attach to Agent and Ask About This.
struct FileSpanActions: View {
  let span: FileTextSpan
  let review: FileReviewContext
  /// Comments need the saved text, so they wait for edits to be saved.
  var commentDisabled = false
  let comment: (FileTextSpan) -> Void

  var body: some View {
    if review.canComment {
      Button("Comment", systemImage: "text.bubble") { comment(span) }
        .disabled(commentDisabled)
        .help(commentDisabled ? "Save your changes to comment on a selection." : "Add a comment")
        .accessibilityIdentifier("workspace.review.comment")
    }
    if let attach = review.attach {
      Button("Attach to Agent", systemImage: "paperclip") { attach(span) }
        .help("Attach \(span.linesTitle) to your next message")
        .accessibilityIdentifier("workspace.review.attach")
    }
    if let ask = review.ask {
      Button("Ask About This", systemImage: "questionmark.bubble") { ask(span) }
        .help("Quote this in the message box")
        .accessibilityIdentifier("workspace.review.ask")
    }
  }
}

/// Writes a comment on a span.
struct CommentComposer: View {
  let span: FileTextSpan
  let add: (String, FileTextSpan) async throws(WorkspaceFailure) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var isSending = false
  @State private var failure: String?
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Comment on \(span.linesTitle)")
        .font(.headline)
      Text(span.text)
        .font(WorkspaceTheme.code)
        .lineLimit(4)
        .foregroundStyle(.secondary)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
      TextField("Add a comment…", text: $text, axis: .vertical)
        .lineLimit(3...8)
        .textFieldStyle(.roundedBorder)
        .focused($focused)
        .accessibilityIdentifier("workspace.review.commentText")
      if let failure {
        Label(failure, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Add Comment") { send() }
          .keyboardShortcut(.defaultAction)
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
          .accessibilityIdentifier("workspace.review.commentSend")
      }
    }
    .padding(16)
    .frame(minWidth: 320, idealWidth: 420)
    .onAppear { focused = true }
  }

  private func send() {
    isSending = true
    failure = nil
    Task {
      do throws(WorkspaceFailure) {
        try await add(text, span)
        dismiss()
      } catch {
        failure = error.message
      }
      isSending = false
    }
  }
}

/// The viewer header's Comments toggle, with the open comments' count, as the web's toolbar.
struct FileCommentsToggle: View {
  let openCount: Int
  @Binding var isShown: Bool

  var body: some View {
    Toggle(isOn: $isShown) {
      Label(openCount > 0 ? "\(openCount)" : "Comments", systemImage: "text.bubble")
        .labelStyle(.titleAndIcon)
        .font(.caption)
    }
    .toggleStyle(.button)
    .buttonStyle(.borderless)
    .fixedSize()
    .help(isShown ? "Hide comments" : "Show comments")
    .accessibilityLabel("Comments, \(openCount) open")
    .accessibilityIdentifier("workspace.review.comments")
  }
}
