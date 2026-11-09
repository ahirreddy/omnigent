#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  @testable import OmnigentWorkspaceUI

  /// What the model types do on the paths the larger suites don't take.
  @MainActor
  @Suite("Workspace model gaps")
  struct WorkspaceModelGapsTests {
    /// Holds a save open until the test has edited the text beneath it.
    private final class SaveGate {
      var written: [String] = []
      var release: CheckedContinuation<Void, Never>?
      var isWaiting: Bool { release != nil }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
      for _ in 0..<500 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
      }
      #expect(condition(), "waited too long")
    }

    @Test("identities are the path, so a list keeps a row across reloads")
    func identities() {
      let file = WorkspaceFile(
        path: "a/b.txt", byteCount: 0, preview: .text(TextPreview(text: "", lineCount: 0)))
      #expect(file.id == "a/b.txt")
      #expect(WorkspaceEntry(path: "a/c.txt", kind: .file).id == "a/c.txt")
      let renamed = FileDiff(
        oldPath: "old.txt", newPath: "new.txt", change: .renamed, hunks: [], splitRows: [],
        added: 0,
        removed: 0)
      #expect(renamed.id == "new.txt")
      let deleted = FileDiff(
        oldPath: "gone.txt", newPath: nil, change: .deleted, hunks: [], splitRows: [], added: 0,
        removed: 1)
      #expect(deleted.id == "gone.txt")
    }

    @Test("a span's identity tells apart two ranges of one file")
    func spanIdentity() {
      func span(_ start: UInt64, _ end: UInt64) -> FileTextSpan {
        FileTextSpan(path: "a.txt", start: start, end: end, firstLine: 1, lastLine: 1, text: "x")
      }
      #expect(span(1, 4).id == "a.txt#1-4")
      #expect(span(1, 4).id != span(1, 5).id)
    }

    @Test("UTF-8 offsets that fall inside a character give no range")
    func splitCharacter() throws {
      let text = "é!"
      let whole = try #require(TextRange(start: 0, end: 2).utf8Range(in: text))
      #expect(text[whole] == "é")
      #expect(TextRange(start: 1, end: 2).utf8Range(in: text) == nil, "starts inside é")
      #expect(TextRange(start: 0, end: 1).utf8Range(in: text) == nil, "ends inside é")
      #expect(TextRange(start: 0, end: 9).utf8Range(in: text) == nil, "past the end")
    }

    @Test("moving through changed files steps from the selection and stops at the ends")
    func changesSelection() async throws {
      let changes = ChangesModel(source: SampleWorkspaceDataSource())
      await changes.reload()
      let paths = try #require(changes.state.value?.files.map(\.path))
      try #require(paths.count >= 2)
      changes.selection = paths[0]
      changes.moveSelection(by: 1)
      #expect(changes.selection == paths[1])
      changes.moveSelection(by: -50)
      #expect(changes.selection == paths[0])
      changes.moveSelection(by: 50)
      #expect(changes.selection == paths.last)
    }

    @Test("typing during a save counts as unsaved and saves again on its own")
    func editDuringSave() async throws {
      let gate = SaveGate()
      let write: (String, String?) async throws(WorkspaceFailure) -> FileSaveResult = { text, _ in
        gate.written.append(text)
        if gate.written.count == 1 {
          await withCheckedContinuation { gate.release = $0 }
        }
        return .saved
      }
      let editor = FileEditor(path: "a.txt", text: "one", lineEnding: .lf, write: write)
      editor.autosaveDelay = nil
      editor.text = "two"
      editor.autosaveDelay = .milliseconds(1)
      let firstSave = Task { await editor.save() }
      try await waitUntil { gate.isWaiting }
      #expect(editor.status == .saving)
      editor.text = "three"
      #expect(editor.status == .saving, "the running save still owns the status")
      gate.release?.resume()
      await firstSave.value
      try await waitUntil { gate.written.count == 2 }
      #expect(gate.written == ["two", "three"])
      try await waitUntil { editor.status == .saved }
      #expect(!editor.isDirty)
    }

    @Test("Saved shows briefly, then the status reads clean")
    func savedNoticeClears() async throws {
      let editor = ReviewFixtures.editor(text: "one")
      editor.savedNoticeDuration = .milliseconds(1)
      editor.text = "two"
      await editor.save()
      try await waitUntil { editor.status == .clean }
      #expect(!editor.isDirty)
    }

    @Test("the notice waits for the newest save, not the one before it")
    func newerSaveKeepsNotice() async throws {
      let editor = ReviewFixtures.editor(text: "one")
      editor.savedNoticeDuration = .milliseconds(30)
      editor.text = "two"
      await editor.save()
      editor.savedNoticeDuration = .seconds(60)
      editor.text = "three"
      await editor.save()
      try await Task.sleep(for: .milliseconds(90))
      #expect(editor.status == .saved, "the first save's timer was cancelled")
    }

    @Test("the notice leaves a new edit's status alone")
    func newEditKeepsUnsaved() async throws {
      let editor = ReviewFixtures.editor(text: "one")
      editor.savedNoticeDuration = .milliseconds(1)
      editor.text = "two"
      await editor.save()
      editor.text = "three"
      try await Task.sleep(for: .milliseconds(30))
      #expect(editor.status == .unsaved)
    }

    @Test("inline Markdown applies, and text that won't parse reads plainly")
    func inlineMarkdown() {
      struct Unparseable: Error {}
      let bold = FilePreviewView.inlineMarkdown("**a**")
      #expect(String(bold.characters) == "a")
      let plain = FilePreviewView.inlineMarkdown("**a**") { _ in throw Unparseable() }
      #expect(String(plain.characters) == "**a**")
    }

    @Test("a custom code family is used when it exists, and the system font otherwise")
    func codeFontFamily() {
      let typography = CodeTypography.shared
      let saved = typography.family
      defer { typography.family = saved }
      typography.family = "Menlo"
      #expect(EditorHighlighter.codeFont.familyName == "Menlo")
      typography.family = "No Such Family"
      #expect(EditorHighlighter.codeFont.fontName != "No Such Family")
    }
  }
#endif
