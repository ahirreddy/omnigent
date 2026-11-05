public import SwiftUI

/// A file: monospaced text with line numbers and light syntax highlighting, an image with its
/// size, or a note for binary files. Notices say when the core clipped the text or the server
/// truncated the file. `line` scrolls to and marks a 1-based line, for search results. With an
/// editor the text can be edited (the Edit mode), and with a review context lines and
/// selections offer comments and agent actions.
public struct FileViewerView: View {
  private let file: WorkspaceFile
  private let line: UInt64?
  private let source: any WorkspaceDataSource
  private let actions: WorkspaceActions
  private let editor: FileEditor?
  private let review: FileReviewContext?
  @AppStorage("workspace.fileViewMode") private var viewMode = FileViewMode.preview
  @State private var commenting: FileTextSpan?

  /// A viewer.
  /// - Parameters:
  ///   - file: The file and its preview.
  ///   - line: A 1-based line to scroll to and mark.
  ///   - source: Used for absolute paths.
  ///   - actions: Host hooks for reveal and open.
  ///   - editor: Edits the file's text; `nil` keeps it read-only.
  ///   - review: Comments and agent actions; `nil` hides them.
  public init(
    file: WorkspaceFile, line: UInt64? = nil, source: any WorkspaceDataSource,
    actions: WorkspaceActions = .none, editor: FileEditor? = nil,
    review: FileReviewContext? = nil
  ) {
    self.file = file
    self.line = line
    self.source = source
    self.actions = actions
    self.editor = editor
    self.review = review
  }

  /// The view.
  public var body: some View {
    VStack(spacing: 0) {
      FileHeader(
        file: file, source: source, actions: actions, modes: modes,
        viewMode: modes.count > 1 ? modeBinding : nil, review: review)
      Divider()
      switch file.preview {
      case .text(let text):
        if text.serverTruncated || text.clipped {
          NoticeBar(symbol: "scissors", text: notice(for: text))
        }
        content(text)
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
    .sheet(item: $commenting) { span in
      if let review { CommentComposer(span: span, add: review.add) }
    }
    .accessibilityIdentifier("workspace.viewer")
  }

  @ViewBuilder private func content(_ text: TextPreview) -> some View {
    let mode = shownMode
    if let editor, mode == .edit {
      FileEditorView(editor: editor, review: review) { commenting = $0 }
    } else if let previewKind, mode == .preview {
      FilePreviewView(kind: previewKind, text: editor?.text ?? text.text)
    } else if let editor, editor.isDirty {
      // Unsaved edits show as source; comments wait until they are saved.
      CodeTextView(preview: edited(text, editor.text), markedLine: line)
    } else {
      CodeTextView(
        preview: text, markedLine: line, path: file.path, review: review
      ) { commenting = $0 }
    }
  }

  /// Preview for a previewable file, Source, and Edit when the viewer may edit it.
  private var modes: [FileViewMode] {
    var modes: [FileViewMode] = previewKind == nil ? [] : [.preview]
    if case .text = file.preview { modes.append(.source) }
    if editor != nil, actions.canEdit { modes.append(.edit) }
    return modes
  }

  /// The chosen mode when this file offers it, else the first it offers.
  private var shownMode: FileViewMode {
    modes.contains(viewMode) ? viewMode : (modes.first ?? .source)
  }

  private var modeBinding: Binding<FileViewMode> {
    Binding(get: { shownMode }, set: { if $0 != viewMode { viewMode = $0 } })
  }

  private func edited(_ preview: TextPreview, _ text: String) -> TextPreview {
    var preview = preview
    preview.text = text
    return preview
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
  /// The modes the picker offers.
  let modes: [FileViewMode]
  /// The chosen mode, when there is a choice.
  let viewMode: Binding<FileViewMode>?
  let review: FileReviewContext?

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
      if let review, !review.comments.isEmpty {
        FileCommentsMenu(review: review)
      }
      if let viewMode {
        Picker("View", selection: viewMode) {
          ForEach(modes) { Text($0.title).tag($0) }
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
