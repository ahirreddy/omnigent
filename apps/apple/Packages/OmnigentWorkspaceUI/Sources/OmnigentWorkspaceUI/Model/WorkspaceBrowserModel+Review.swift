import Foundation

extension WorkspaceBrowserModel {
  /// Whether a file's text can be edited here: complete text with one kind of line break.
  /// - Parameter file: The file.
  /// - Returns: The text preview to edit, or `nil`.
  public static func editableText(of file: WorkspaceFile) -> TextPreview? {
    guard case .text(let text) = file.preview, !text.clipped, !text.serverTruncated,
      text.lineEnding != .mixed
    else { return nil }
    return text
  }

  /// Keeps an editor for every opened text file; a file read again updates its editor.
  func prepareEditor(for file: WorkspaceFile) {
    guard let text = Self.editableText(of: file) else { return }
    if let editor = editors[file.path] {
      editor.serverChanged(text.text)
      return
    }
    let source = source
    let path = file.path
    editors[file.path] = FileEditor(
      path: path, text: text.text, lineEnding: text.lineEnding
    ) { content, base throws(WorkspaceFailure) in
      try await source.save(path, text: content, base: base)
    }
  }

  /// Reads the open review comments on `file`.
  func loadComments(for file: WorkspaceFile) async {
    guard case .text(let text) = file.preview else { return }
    if comments[file.path]?.value == nil { comments[file.path] = .loading }
    do {
      comments[file.path] = .loaded(try await source.comments(on: file.path, text: text.text))
    } catch {
      comments[file.path] = .failed(error)
    }
  }

  /// Leaves a review comment on `span` and reads the file's comments again.
  /// - Parameters:
  ///   - body: The comment.
  ///   - span: What it is about.
  /// - Throws: The failure to show.
  public func addComment(_ body: String, on span: FileTextSpan) async throws(WorkspaceFailure) {
    try await source.addComment(body, on: span)
    if let file = file.value, file.path == span.path { await loadComments(for: file) }
  }

  /// Finishes the close `pendingClose` waits on: saves first (the tab stays open when that
  /// fails or conflicts), or discards the edits.
  /// - Parameter save: Save the edits rather than discard them.
  public func finishPendingClose(saving save: Bool) async {
    guard let document = pendingClose else { return }
    pendingClose = nil
    guard let editor = editors[document.path] else {
      await close(document)
      return
    }
    if save {
      await editor.save()
      guard !editor.isDirty else { return }
    } else {
      editor.revert()
    }
    editors[document.path] = nil
    await close(document)
  }

  /// Paths with edits not yet saved.
  public var unsavedPaths: [String] {
    editors.values.filter(\.isDirty).map(\.path).sorted()
  }
}
