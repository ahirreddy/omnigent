public import SwiftUI

/// A file: monospaced text with line numbers and light syntax highlighting, an image with its
/// size, or a note for binary files. Notices say when the core clipped the text or the server
/// truncated the file. `line` scrolls to and marks a 1-based line, for search results.
public struct FileViewerView: View {
  private let file: WorkspaceFile
  private let line: UInt64?
  private let source: any WorkspaceDataSource
  private let actions: WorkspaceActions
  @AppStorage("workspace.fileViewMode") private var viewMode = FileViewMode.preview

  /// A viewer.
  /// - Parameters:
  ///   - file: The file and its preview.
  ///   - line: A 1-based line to scroll to and mark.
  ///   - source: Used for absolute paths.
  ///   - actions: Host hooks for reveal and open.
  public init(
    file: WorkspaceFile, line: UInt64? = nil, source: any WorkspaceDataSource,
    actions: WorkspaceActions = .none
  ) {
    self.file = file
    self.line = line
    self.source = source
    self.actions = actions
  }

  /// The view.
  public var body: some View {
    VStack(spacing: 0) {
      FileHeader(
        file: file, source: source, actions: actions,
        viewMode: previewKind == nil ? nil : $viewMode)
      Divider()
      switch file.preview {
      case .text(let text):
        if text.serverTruncated || text.clipped {
          NoticeBar(symbol: "scissors", text: notice(for: text))
        }
        if let previewKind, viewMode == .preview {
          FilePreviewView(kind: previewKind, text: text.text)
        } else {
          CodeTextView(preview: text, markedLine: line)
        }
      case .image(let format, let data):
        ImagePreview(format: format, data: data, byteCount: file.byteCount)
      case .binary(let reason):
        ContentUnavailableView {
          Label("No Preview", systemImage: "doc.questionmark")
        } description: {
          Text("\(reason.explanation) \(file.byteCount.formatted(.byteCount(style: .file))).")
        }
      }
    }
    .accessibilityIdentifier("workspace.viewer")
  }

  private var previewKind: FilePreviewKind? {
    guard case .text = file.preview else { return nil }
    return FilePreviewKind.of(path: file.path)
  }

  private func notice(for text: TextPreview) -> String {
    let lines = text.lineCount.formatted()
    if text.clipped {
      return "Showing the first \(lines) lines. Open the file to see all of it."
    }
    return "The server returned the first \(file.byteCount.formatted(.byteCount(style: .file)))."
  }
}

private struct FileHeader: View {
  let file: WorkspaceFile
  let source: any WorkspaceDataSource
  let actions: WorkspaceActions
  /// Preview or Source, for a previewable file.
  let viewMode: Binding<FileViewMode>?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: FileIcons.symbol(forName: WorkspacePaths.name(of: file.path)))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(WorkspacePaths.name(of: file.path))
          .font(.headline)
          .lineLimit(1)
        Text(file.path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
          .textSelection(.enabled)
      }
      Spacer(minLength: 8)
      if let viewMode {
        Picker("View", selection: viewMode) {
          ForEach(FileViewMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("workspace.viewer.mode")
      } else {
        Text(details)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Menu {
        PathMenu(path: file.path, source: source, actions: actions)
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel("File actions")
      }
      .menuStyle(.button)
      .buttonStyle(.borderless)
      .fixedSize()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var details: String {
    var parts: [String] = []
    if case .text(let text) = file.preview {
      if let language = text.language { parts.append(language.displayName) }
      parts.append("\(text.lineCount.formatted()) lines")
      parts.append(text.lineEnding.rawValue)
    } else if case .image(let format, _) = file.preview {
      parts.append(format.rawValue)
    }
    parts.append(file.byteCount.formatted(.byteCount(style: .file)))
    return parts.joined(separator: "  ")
  }
}

/// Lines with a gutter, rendered lazily so a long file scrolls smoothly.
struct CodeTextView: View {
  let preview: TextPreview
  let markedLine: UInt64?

  @Environment(\.colorScheme) private var scheme

  private var lines: [Substring] {
    var lines = preview.text.split(separator: "\n", omittingEmptySubsequences: false)
    if preview.text.hasSuffix("\n") { lines.removeLast() }
    return lines
  }

  var body: some View {
    let lines = lines
    let digits = max(String(lines.count).count, 2)
    let highlighter =
      preview.skipHighlighting ? nil : preview.language.map { SyntaxHighlighter(language: $0) }
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView([.vertical, .horizontal]) {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
              CodeLine(
                number: index + 1, digits: digits, text: line, highlighter: highlighter,
                isMarked: markedLine == UInt64(index + 1)
              )
              .id(index + 1)
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
}

private struct CodeLine: View {
  let number: Int
  let digits: Int
  let text: Substring
  let highlighter: SyntaxHighlighter?
  let isMarked: Bool

  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      Text(String(number))
        .font(WorkspaceTheme.gutter)
        .foregroundStyle(.tertiary)
        .frame(width: CGFloat(digits) * 7.5 + 12, alignment: .trailing)
        .padding(.trailing, 10)
        .accessibilityHidden(true)
      Text(highlighted)
        .font(WorkspaceTheme.code)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 16)
    }
    .frame(maxWidth: .infinity, minHeight: WorkspaceTheme.lineHeight, alignment: .leading)
    .background(isMarked ? WorkspaceTheme.matchBackground(scheme) : .clear)
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

private struct ImagePreview: View {
  let format: ImageFormat
  let data: Data
  let byteCount: UInt64

  var body: some View {
    if let decoded = WorkspacePlatform.image(from: data) {
      VStack(spacing: 8) {
        decoded.image
          .resizable()
          .interpolation(.none)
          .scaledToFit()
          .frame(maxWidth: max(decoded.size.width, 64) * 4, maxHeight: 420)
          .background(Checkerboard())
          .border(.separator)
          .accessibilityLabel("Image preview")
        Text("\(Int(decoded.size.width)) x \(Int(decoded.size.height)) \(format.rawValue)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView(
        "Cannot Display Image", systemImage: "photo.badge.exclamationmark",
        description: Text("This \(format.rawValue) image could not be decoded."))
    }
  }
}

/// The transparency checkerboard behind images.
private struct Checkerboard: View {
  var body: some View {
    Canvas { context, size in
      let cell: CGFloat = 8
      for row in 0..<Int(size.height / cell) + 1 {
        for column in 0..<Int(size.width / cell) + 1 where (row + column).isMultiple(of: 2) {
          context.fill(
            Path(
              CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
            with: .color(.gray.opacity(0.18)))
        }
      }
    }
  }
}

#Preview("Text file") {
  FileViewerView(
    file: WorkspaceSamples.mainFile, line: 3, source: SampleWorkspaceDataSource()
  )
  .frame(width: 640, height: 360)
}

#Preview("Image") {
  FileViewerView(file: WorkspaceSamples.logoFile, source: SampleWorkspaceDataSource())
    .frame(width: 480, height: 360)
}
