public import SwiftUI

/// What the file viewer offers for reviewing a file: its comments, leaving new ones, and
/// handing a span to the agent.
public struct FileReviewContext {
  /// The file's open comments.
  public var comments: [FileCommentLine]
  /// The viewer may leave comments.
  public var canComment: Bool
  /// Leaves a comment.
  public var add: (String, FileTextSpan) async throws(WorkspaceFailure) -> Void
  /// Scrolls to and marks a line.
  public var reveal: (UInt64) -> Void
  /// Attaches a span to the agent's next message; `nil` hides it.
  public var attach: ((FileTextSpan) -> Void)?
  /// Quotes a span into the composer to ask about it; `nil` hides it.
  public var ask: ((FileTextSpan) -> Void)?

  /// A context.
  /// - Parameters:
  ///   - comments: The file's open comments.
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

  /// The comments by the line they start on.
  var commentsByLine: [UInt64: [FileCommentLine]] {
    Dictionary(grouping: comments.filter { $0.line != nil }) { $0.line ?? 0 }
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
      TextField("Add a comment", text: $text, axis: .vertical)
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
        Button("Comment") { send() }
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

/// The file's comments, for the viewer's header: each one scrolls to its line.
struct FileCommentsMenu: View {
  let review: FileReviewContext

  var body: some View {
    Menu {
      ForEach(review.comments) { comment in
        Button {
          if let line = comment.line { review.reveal(line) }
        } label: {
          Text(comment.line.map { "Line \($0): \(comment.body)" } ?? comment.body)
        }
        .disabled(comment.line == nil)
      }
    } label: {
      Label("\(review.comments.count)", systemImage: "text.bubble")
        .labelStyle(.titleAndIcon)
        .font(.caption)
    }
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Comments on this file")
    .accessibilityLabel("\(review.comments.count) comments")
    .accessibilityIdentifier("workspace.review.comments")
  }
}

/// The comments that start on one line, behind the gutter's marker.
struct LineCommentsPopover: View {
  let comments: [FileCommentLine]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(comments) { comment in
        VStack(alignment: .leading, spacing: 2) {
          Text(comment.author ?? "Comment")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(comment.body)
            .textSelection(.enabled)
        }
      }
    }
    .padding(12)
    .frame(minWidth: 220, maxWidth: 360, alignment: .leading)
  }
}
