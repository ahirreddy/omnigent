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
    await reloadComments(on: span.path)
  }

  // swiftlint:disable discouraged_optional_boolean
  /// Edits, resolves or reopens a comment on `path`, then reads the file's comments again.
  /// - Parameters:
  ///   - id: The comment.
  ///   - path: Its file.
  ///   - body: The new text; `nil` keeps it.
  ///   - open: The new state; `nil` keeps it.
  /// - Throws: The failure to show.
  public func updateComment(_ id: String, on path: String, body: String? = nil, open: Bool? = nil)
    async throws(WorkspaceFailure)
  {
    try await source.updateComment(id, body: body, open: open)
    await reloadComments(on: path)
  }
  // swiftlint:enable discouraged_optional_boolean

  /// Deletes a comment on `path`, then reads the file's comments again.
  /// - Parameters:
  ///   - id: The comment.
  ///   - path: Its file.
  /// - Throws: The failure to show.
  public func deleteComment(_ id: String, on path: String) async throws(WorkspaceFailure) {
    try await source.deleteComment(id)
    await reloadComments(on: path)
  }

  /// Sends `path`'s open comments to the agent as one message ("Address All"), then reads them
  /// again. A failed send leaves them open, so the comments are read again then too.
  /// - Parameter path: The file.
  /// - Throws: The failure to show.
  public func sendOpenComments(on path: String) async throws(WorkspaceFailure) {
    let ids = (comments[path]?.value ?? []).filter(\.isOpen).map(\.id)
    guard !ids.isEmpty else { return }
    do {
      try await source.sendCommentsToAgent(ids)
    } catch {
      await reloadComments(on: path)
      throw error
    }
    await reloadComments(on: path)
  }

  private func reloadComments(on path: String) async {
    if let file = file.value, file.path == path { await loadComments(for: file) }
  }

  /// Finishes the close `pendingClose` waits on: saves first (the tab stays open when that
  /// fails or conflicts), or discards the edits.
  /// - Parameter save: Save the edits rather than discard them.
  public func finishPendingClose(saving save: Bool) async {
    guard let document = pendingClose else { return }
    await finishClose(of: document, saving: save)
  }

  /// Finishes closing `document` after the question was answered. The answer's button passes the
  /// document, since dismissing the question clears `pendingClose` before its task runs.
  /// - Parameters:
  ///   - document: The document the question was about.
  ///   - save: Whether to save its edits first.
  public func finishClose(of document: WorkspaceDocument, saving save: Bool) async {
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

  /// Saves every unsaved edit now, as when a window closes or the app quits or goes to the
  /// background. Edits held by a conflict stay unsaved.
  /// - Returns: The paths still unsaved: a save failed or waits on a conflict.
  @discardableResult
  public func saveAll() async -> [String] {
    for editor in editors.values where editor.isDirty && editor.conflict == nil {
      await editor.save()
    }
    return unsavedPaths
  }

  /// Discards every unsaved edit, keeping the last saved text.
  public func discardAll() {
    for editor in editors.values where editor.isDirty || editor.conflict != nil { editor.revert() }
  }
}
