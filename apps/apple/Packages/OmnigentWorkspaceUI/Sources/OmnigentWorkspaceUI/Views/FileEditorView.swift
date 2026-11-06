import SwiftUI

/// Edits a text file: a highlighted code editor with the save status and Save (Command-S), a
/// banner for a change made elsewhere under unsaved edits, review actions for the selection,
/// and for Markdown the web's formatting toolbar.
struct FileEditorView: View {
  let editor: FileEditor
  let language: SyntaxLanguage?
  let isMarkdown: Bool
  let review: FileReviewContext?
  let comment: (FileTextSpan) -> Void
  /// The selected characters, in UTF-16 offsets; `nil` for a caret.
  @State private var selection: NSRange?
  @State private var controller = CodeEditorController()

  var body: some View {
    VStack(spacing: 0) {
      if let conflict = editor.conflict {
        ConflictBanner(editor: editor, conflict: conflict)
        Divider()
      }
      SaveBar(editor: editor)
      Divider()
      if isMarkdown {
        MarkdownToolbar(controller: controller)
        Divider()
      }
      #if os(iOS)
        // Above the text, where the keyboard never covers it.
        selectionBar
      #endif
      CodeEditorTextView(
        editor: editor, language: language, controller: controller
      ) { range in
        if range != selection { selection = range }
      }
      #if os(macOS)
        selectionBar
      #endif
    }
  }

  /// The selection's lines and review actions.
  @ViewBuilder private var selectionBar: some View {
    if let review, let span = selectedSpan {
      #if os(macOS)
        Divider()
      #endif
      HStack(spacing: 12) {
        Text(span.linesTitle.capitalized)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        FileSpanActions(
          span: span, review: review, commentDisabled: editor.isDirty, comment: comment)
      }
      .labelStyle(.titleAndIcon)
      .buttonStyle(.borderless)
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("workspace.editor.selection")
      #if os(iOS)
        Divider()
      #endif
    }
  }

  private var selectedSpan: FileTextSpan? {
    guard let selection, let range = Range(selection, in: editor.text) else { return nil }
    return FileTextSpan.selection(
      range, in: editor.text, path: editor.path, crlf: editor.usesCRLF)
  }
}

/// The web's Markdown formatting buttons over the source: inline marks and block markers.
private struct MarkdownToolbar: View {
  let controller: CodeEditorController

  private static let groups: [[MarkdownFormat]] = [
    [.paragraph, .heading1, .heading2, .heading3, .quote],
    [.bold, .italic, .strikethrough, .code, .link],
    [.bulletList, .numberedList, .taskList],
  ]

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 2) {
        ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
          if index > 0 { Divider().frame(height: 16).padding(.horizontal, 4) }
          ForEach(group) { format in button(format) }
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
    }
    .scrollIndicators(.hidden)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace.editor.markdownToolbar")
  }

  @ViewBuilder private func button(_ format: MarkdownFormat) -> some View {
    let button = Button(format.title, systemImage: format.systemImage) { controller.apply(format) }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .frame(minWidth: 26, minHeight: 24)
      .help(help(format))
      .accessibilityIdentifier("workspace.editor.format.\(format.rawValue)")
    switch format {
    case .bold: button.keyboardShortcut("b", modifiers: .command)
    case .italic: button.keyboardShortcut("i", modifiers: .command)
    default: button
    }
  }

  private func help(_ format: MarkdownFormat) -> String {
    switch format {
    case .bold: "Bold (Command-B)"
    case .italic: "Italic (Command-I)"
    default: format.title
    }
  }
}

/// The edit's status ("Unsaved", "Saving…", "Saved", "Save failed") with Save and Revert.
private struct SaveBar: View {
  let editor: FileEditor

  var body: some View {
    HStack(spacing: 8) {
      status
      Spacer(minLength: 8)
      Button("Revert") { editor.revert() }
        .disabled(!editor.isDirty || editor.status == .saving)
        .help("Discard unsaved changes")
        .accessibilityIdentifier("workspace.editor.revert")
      Button("Save") { Task { await editor.save() } }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!editor.isDirty || editor.status == .saving || editor.conflict != nil)
        .help("Save (Command-S)")
        .accessibilityIdentifier("workspace.editor.save")
    }
    .buttonStyle(.borderless)
    .font(.caption)
    .padding(.horizontal, 12)
    .padding(.vertical, 5)
  }

  @ViewBuilder private var status: some View {
    switch editor.status {
    case .clean:
      Label("Edits save automatically", systemImage: "pencil")
        .foregroundStyle(.secondary)
    case .unsaved:
      Label("Unsaved", systemImage: "circle.fill")
        .foregroundStyle(.orange)
    case .saving:
      HStack(spacing: 4) {
        ProgressView().controlSize(.mini)
        Text("Saving…")
      }
      .foregroundStyle(.secondary)
    case .saved:
      Label("Saved", systemImage: "checkmark.circle")
        .foregroundStyle(.green)
    case .failed(let message):
      Label("Save failed: \(message)", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .lineLimit(2)
    }
  }
}

/// A change made elsewhere while there were unsaved edits: keep mine or load the latest.
private struct ConflictBanner: View {
  let editor: FileEditor
  let conflict: FileEditor.Conflict

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(
        conflict.latest == nil
          ? "This file was deleted or replaced while you were editing."
          : "This file was modified externally while you were editing."
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      Button("Keep Mine") { Task { await editor.save(force: true) } }
        .accessibilityIdentifier("workspace.editor.keepMine")
      Button(conflict.latest == nil ? "Discard Mine" : "Load Latest") { editor.loadLatest() }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("workspace.editor.loadLatest")
    }
    .font(.callout)
    .buttonStyle(.bordered)
    .controlSize(.small)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.orange.opacity(0.12))
  }
}
