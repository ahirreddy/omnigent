import SwiftUI

/// Edits a text file: a monospaced editor with the save status and Save (Command-S), a banner
/// for a change made elsewhere under unsaved edits, and review actions for the selection.
struct FileEditorView: View {
  @Bindable var editor: FileEditor
  let review: FileReviewContext?
  let comment: (FileTextSpan) -> Void
  @State private var selection: TextSelection?

  var body: some View {
    VStack(spacing: 0) {
      if let conflict = editor.conflict {
        ConflictBanner(editor: editor, conflict: conflict)
        Divider()
      }
      SaveBar(editor: editor)
      Divider()
      TextEditor(text: $editor.text, selection: $selection)
        .font(WorkspaceTheme.code)
        .autocorrectionDisabled()
        #if os(iOS)
          .textInputAutocapitalization(.never)
        #endif
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 6)
        .accessibilityIdentifier("workspace.editor")
      if let review, let span = selectedSpan {
        Divider()
        HStack(spacing: 12) {
          Text(span.linesTitle.capitalized)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
          FileSpanActions(
            span: span, review: review, commentDisabled: editor.isDirty || editor.usesCRLF,
            comment: comment)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("workspace.editor.selection")
      }
    }
  }

  private var selectedSpan: FileTextSpan? {
    guard let selection, case .selection(let range) = selection.indices, !range.isEmpty,
      range.upperBound <= editor.text.endIndex
    else { return nil }
    return FileTextSpan.selection(range, in: editor.text, path: editor.path)
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
