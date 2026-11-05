import SwiftUI

/// Lines with a gutter, rendered lazily so a long file scrolls smoothly. With a review context,
/// lines with comments show a marker in the gutter and every line's context menu offers
/// Comment, Attach to Agent and Ask About This (a long press on touch screens).
struct CodeTextView: View {
  let preview: TextPreview
  let markedLine: UInt64?
  var path = ""
  var review: FileReviewContext?
  /// Opens the comment composer for a span.
  var comment: (FileTextSpan) -> Void = { _ in }

  @Environment(\.colorScheme) private var scheme

  /// Split on `\n` scalars, so CRLF lines (one `Character` each) split too.
  private var lines: [Substring] {
    var lines = preview.text.unicodeScalars
      .split(separator: "\n", omittingEmptySubsequences: false).map(Substring.init)
    if preview.text.unicodeScalars.last == "\n" { lines.removeLast() }
    return lines
  }

  var body: some View {
    let lines = lines
    let digits = max(String(lines.count).count, 2)
    let highlighter =
      preview.skipHighlighting ? nil : preview.language.map { SyntaxHighlighter(language: $0) }
    let commentsByLine = review?.commentsByLine ?? [:]
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView([.vertical, .horizontal]) {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
              CodeLine(
                number: index + 1, digits: digits, text: line, highlighter: highlighter,
                isMarked: markedLine == UInt64(index + 1),
                comments: commentsByLine[UInt64(index + 1)] ?? []
              )
              .id(index + 1)
              .contextMenu { lineMenu(UInt64(index + 1)) }
            }
          }
          .padding(.vertical, 6)
          .frame(minWidth: geometry.size.width, alignment: .leading)
          .textSelection(.enabled)
        }
        .defaultScrollAnchor(.topLeading, for: .alignment)
        .background(scheme == .dark ? Color.black.opacity(0.15) : Color.white)
        .onAppear {
          if let markedLine { proxy.scrollTo(Int(markedLine), anchor: .center) }
        }
        .onChange(of: markedLine) { _, line in
          if let line { proxy.scrollTo(Int(line), anchor: .center) }
        }
      }
    }
  }

  @ViewBuilder private func lineMenu(_ line: UInt64) -> some View {
    if let review, let span = FileTextSpan.line(line, in: preview.text, path: path) {
      FileSpanActions(span: span, review: review, comment: comment)
      Divider()
      Button("Copy Line", systemImage: "doc.on.doc") { WorkspacePlatform.copy(span.text) }
    }
  }
}

private struct CodeLine: View {
  let number: Int
  let digits: Int
  let text: Substring
  let highlighter: SyntaxHighlighter?
  let isMarked: Bool
  let comments: [FileCommentLine]

  @Environment(\.colorScheme) private var scheme
  @State private var showsComments = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      gutter
      Text(highlighted)
        .font(WorkspaceTheme.code)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 16)
    }
    .frame(maxWidth: .infinity, minHeight: WorkspaceTheme.lineHeight, alignment: .leading)
    .background(isMarked ? WorkspaceTheme.matchBackground(scheme) : .clear)
  }

  @ViewBuilder private var gutter: some View {
    if comments.isEmpty {
      Text(String(number))
        .font(WorkspaceTheme.gutter)
        .foregroundStyle(.tertiary)
        .frame(width: CGFloat(digits) * 7.5 + 12, alignment: .trailing)
        .padding(.trailing, 10)
        .accessibilityHidden(true)
    } else {
      Button {
        showsComments = true
      } label: {
        HStack(spacing: 2) {
          Image(systemName: "text.bubble.fill")
            .font(.system(size: 9))
            .foregroundStyle(Color.accentColor)
          Text(String(number))
            .font(WorkspaceTheme.gutter)
            .foregroundStyle(.secondary)
        }
        .frame(width: CGFloat(digits) * 7.5 + 12, alignment: .trailing)
      }
      .buttonStyle(.plain)
      .padding(.trailing, 10)
      .popover(isPresented: $showsComments) { LineCommentsPopover(comments: comments) }
      .accessibilityLabel("\(comments.count) comments on line \(number)")
    }
  }

  private var highlighted: AttributedString {
    let line = String(text.hasSuffix("\r") ? text.dropLast() : text)
    return Highlighting.attributed(line, highlighter: highlighter, scheme: scheme)
  }
}

/// Builds `AttributedString`s for code lines.
enum Highlighting {
  static func attributed(
    _ line: String, highlighter: SyntaxHighlighter?, scheme: ColorScheme
  ) -> AttributedString {
    var attributed = AttributedString(line)
    guard let highlighter else { return attributed }
    for span in highlighter.spans(in: line) {
      guard
        let range = TextRange(start: span.range.lowerBound, end: span.range.upperBound)
          .utf16Range(in: line),
        let lower = AttributedString.Index(range.lowerBound, within: attributed),
        let upper = AttributedString.Index(range.upperBound, within: attributed)
      else { continue }
      attributed[lower..<upper].foregroundColor = WorkspaceTheme.tokenColor(span.token, scheme)
    }
    return attributed
  }

  /// `text` with `range` (UTF-16 or UTF-8 offsets) given `background`.
  static func marked(
    _ text: String, range: Range<String.Index>?, background: Color
  ) -> AttributedString {
    var attributed = AttributedString(text)
    guard let range,
      let lower = AttributedString.Index(range.lowerBound, within: attributed),
      let upper = AttributedString.Index(range.upperBound, within: attributed)
    else { return attributed }
    attributed[lower..<upper].backgroundColor = background
    attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
    return attributed
  }
}
