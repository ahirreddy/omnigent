import SwiftUI
import UniformTypeIdentifiers

/// A description being edited: its Markdown, the uploads still landing in it, and the last
/// failure. The detail view keeps it, so it survives a switch to another tab.
nonisolated struct PullRequestDescriptionDraft: Equatable, Sendable {
  /// The text it started from; saving it unchanged just closes the editor.
  var original: String
  /// The Markdown.
  var body: String
  /// Uploads in flight.
  var uploading = 0
  /// Uploads started, for their placeholders.
  var uploads = 0
  /// Why the last upload or save failed.
  var error: String?
  /// Where the next attachment goes, in characters; `nil` puts it at the end. A SwiftUI text
  /// editor that shares its selection loses typing, so the editor leaves this unset.
  var insertion: Range<Int>?

  /// The placeholder an upload shows until it lands, on a line of its own.
  static func placeholder(_ name: String, _ index: Int) -> String {
    "![Uploading \(name.isEmpty ? "file" : name)\u{2026}](#upload-\(index))"
  }

  /// `text` added at the end on a line of its own, as a video address needs.
  mutating func append(_ text: String) {
    if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
    body += text
  }

  /// `text` on a line of its own in place of the selection, or at the end without one, as the
  /// web's `insertOnOwnLine`; the next attachment goes after it.
  mutating func insert(_ text: String) {
    let count = body.count
    let start = min(insertion?.lowerBound ?? count, count)
    let end = min(max(insertion?.upperBound ?? start, start), count)
    let from = body.index(body.startIndex, offsetBy: start)
    let to = body.index(body.startIndex, offsetBy: end)
    let before = start > 0 && body[body.index(before: from)] != "\n" ? "\n" : ""
    let after = end < count && body[to] != "\n" ? "\n" : ""
    let inserted = before + text + after
    body.replaceSubrange(from..<to, with: inserted)
    let caret = start + inserted.count
    insertion = caret..<caret
  }
}

/// The Summary tab's Description: the rendered Markdown, or for editors a Write and Preview
/// editor that uploads images and videos into it, as the web's `PullRequestDescription` does.
struct PullRequestDescriptionSection: View {
  let state: PullRequestDetailViewState
  let extras: PullRequestPanelExtras
  @Binding var draft: PullRequestDescriptionDraft?

  private enum Mode: Hashable { case write, preview }

  @State private var mode = Mode.write
  @State private var importing = false
  @State private var confirmingDiscard = false

  private var canEdit: Bool { state.canEditDetails && extras.actions.editDetails != nil }
  private var canAttach: Bool { state.canAttach && extras.actions.attach != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      PullRequestSectionHeading(title: "Description") {
        if canEdit, draft == nil {
          Button {
            draft = PullRequestDescriptionDraft(original: state.body ?? "", body: state.body ?? "")
          } label: {
            Image(systemName: "pencil").accessibilityLabel("Edit description")
          }
          .buttonStyle(.borderless)
          .help("Edit description")
          .accessibilityIdentifier("pr-edit-description")
        }
      }
      if canEdit, let current = draft {
        editor(current)
      } else if let body = state.body {
        MarkdownView(body).textSelection(.enabled)
      } else {
        Text("No description provided.").foregroundStyle(.secondary)
      }
    }
  }

  private func editor(_ current: PullRequestDescriptionDraft) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      HStack {
        Picker("Description editor", selection: $mode) {
          Text("Write").tag(Mode.write)
          Text("Preview").tag(Mode.preview)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Spacer(minLength: 0)
        if canAttach {
          Button {
            importing = true
          } label: {
            Image(systemName: "paperclip").accessibilityLabel("Attach images or videos")
          }
          .buttonStyle(.borderless)
          .help("Attach images or videos")
        }
      }
      content(current)
        .frame(minHeight: 160, maxHeight: 320)
        .overlay {
          RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(.separator)
        }
      if let error = current.error {
        Text(error).font(.callout).foregroundStyle(Theme.failure)
      }
      buttons(current)
    }
    .fileImporter(
      isPresented: $importing, allowedContentTypes: [.image, .movie],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let files): files.forEach(attach)
      case .failure(let error): draft?.error = error.localizedDescription
      }
    }
    .confirmationDialog(
      "Discard your description changes?", isPresented: $confirmingDiscard,
      titleVisibility: .visible
    ) {
      Button("Discard", role: .destructive) { draft = nil }
    }
  }

  @ViewBuilder private func content(_ current: PullRequestDescriptionDraft) -> some View {
    switch mode {
    case .write:
      TextEditor(
        text: Binding(
          get: { current.body },
          set: { body in
            draft?.body = body
            draft?.error = nil
          })
      )
      .font(.callout.monospaced())
      .disabled(extras.isBusy)
      .accessibilityLabel("Pull request description")
      .accessibilityIdentifier("pr-description-field")
      // Images and videos dropped on the editor upload into the description, as on the web.
      .dropDestination(for: URL.self) { files, _ in
        let attachable = files.filter(\.isFileURL)
        guard canAttach, !attachable.isEmpty else { return false }
        attachable.forEach(attach)
        return true
      }
    case .preview:
      ScrollView {
        Group {
          if current.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Nothing to preview.").foregroundStyle(.secondary)
          } else {
            MarkdownView(current.body)
          }
        }
        .padding(Theme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func buttons(_ current: PullRequestDescriptionDraft) -> some View {
    HStack(spacing: Theme.Spacing.small) {
      if current.uploading > 0 {
        ProgressView().controlSize(.small)
        Text("Uploading \(current.uploading) \(current.uploading == 1 ? "file" : "files")\u{2026}")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Button("Cancel") {
        if current.body == current.original { draft = nil } else { confirmingDiscard = true }
      }
      .disabled(extras.isBusy)
      Button(extras.isBusy ? "Saving\u{2026}" : "Save") { save(current) }
        .disabled(extras.isBusy || current.uploading > 0)
        .accessibilityIdentifier("pr-save-description")
    }
  }

  private func save(_ current: PullRequestDescriptionDraft) {
    guard current.body != current.original, let edit = extras.actions.editDetails else {
      draft = nil
      return
    }
    edit(nil, current.body) { saved in
      if saved, draft?.body == current.body { draft = nil }
    }
  }

  /// Uploads `file`, showing a placeholder where it goes until it lands.
  private func attach(_ file: URL) {
    guard let upload = extras.actions.attach, var current = draft else { return }
    current.uploads += 1
    let placeholder = PullRequestDescriptionDraft.placeholder(
      file.lastPathComponent, current.uploads)
    current.insert(placeholder)
    current.uploading += 1
    draft = current
    upload(file) { outcome in
      // The editor may have closed, or reopened as a new draft, while it uploaded.
      guard var landing = draft, landing.body.contains(placeholder) else { return }
      landing.uploading = max(landing.uploading - 1, 0)
      switch outcome {
      case .attached(let markdown):
        landing.body = landing.body.replacingOccurrences(of: placeholder, with: markdown)
      case .failed(let message):
        landing.body = landing.body.replacingOccurrences(of: placeholder, with: "")
        landing.error = message
      }
      draft = landing
    }
  }
}
