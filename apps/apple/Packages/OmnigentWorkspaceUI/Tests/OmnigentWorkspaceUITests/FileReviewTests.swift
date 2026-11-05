import Foundation
import Testing

@testable import OmnigentWorkspaceUI

@Suite("File editing and review")
struct FileReviewTests {
  private func editor(
    _ source: SampleWorkspaceDataSource, path: String = "notes.md", text: String,
    lineEnding: LineEnding = .lf
  ) -> FileEditor {
    typealias Save = (String, String?) async throws(WorkspaceFailure) -> FileSaveResult
    let save: Save = { content, base in try await source.save(path, text: content, base: base) }
    let editor = FileEditor(path: path, text: text, lineEnding: lineEnding, write: save)
    editor.autosaveDelay = nil
    return editor
  }

  @Test("an edit saves after checking the file, and a save failure is shown")
  func saves() async {
    let source = SampleWorkspaceDataSource()
    source.savedTexts["notes.md"] = "one\n"
    let editor = editor(source, text: "one\n")
    #expect(editor.status == .clean)
    editor.text = "two\n"
    #expect(editor.status == .unsaved)
    #expect(editor.isDirty)
    await editor.save()
    #expect(source.savedTexts["notes.md"] == "two\n")
    #expect(editor.status == .saved)
    #expect(!editor.isDirty)

    source.failures["#save"] = WorkspaceFailure(.forbidden, message: "Read-only share")
    editor.text = "three\n"
    await editor.save()
    #expect(editor.status == .failed("Read-only share"))
    #expect(editor.isDirty, "a failed save keeps the edit")
  }

  @Test("a change made elsewhere is a conflict: keep mine overwrites, load latest discards")
  func conflicts() async {
    let source = SampleWorkspaceDataSource()
    source.savedTexts["notes.md"] = "base\n"
    let editor = editor(source, text: "base\n")
    editor.text = "mine\n"
    source.savedTexts["notes.md"] = "theirs\n"
    await editor.save()
    #expect(editor.conflict == FileEditor.Conflict(latest: "theirs\n"))
    #expect(source.savedTexts["notes.md"] == "theirs\n", "nothing was written")
    await editor.save(force: true)
    #expect(source.savedTexts["notes.md"] == "mine\n")
    #expect(editor.conflict == nil)

    editor.text = "mine again\n"
    editor.serverChanged("agent wrote this\n")
    #expect(editor.conflict?.latest == "agent wrote this\n")
    editor.loadLatest()
    #expect(editor.text == "agent wrote this\n")
    #expect(!editor.isDirty)
    editor.serverChanged("agent again\n")
    #expect(editor.text == "agent again\n", "clean edits follow the file")
    #expect(editor.conflict == nil)
  }

  @Test("CRLF files are edited with LF and saved with CRLF")
  func lineEndings() async {
    let source = SampleWorkspaceDataSource()
    source.savedTexts["win.txt"] = "a\r\nb\r\n"
    let editor = editor(source, path: "win.txt", text: "a\r\nb\r\n", lineEnding: .crlf)
    #expect(editor.text == "a\nb\n")
    editor.text = "a\nc\n"
    await editor.save()
    #expect(source.savedTexts["win.txt"] == "a\r\nc\r\n")
    #expect(editor.conflict == nil)
  }

  @Test("closing a tab with unsaved edits asks first; discarding closes it")
  func closeAsks() async throws {
    let browser = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
    await browser.open(.file(path: "src/main.rs", line: nil))
    let editor = try #require(browser.editors["src/main.rs"])
    editor.autosaveDelay = nil
    editor.text = "changed"
    await browser.close(.file(path: "src/main.rs", line: nil))
    #expect(browser.pendingClose == .file(path: "src/main.rs", line: nil))
    #expect(browser.openDocuments.count == 1)
    #expect(browser.unsavedPaths == ["src/main.rs"])
    await browser.finishPendingClose(saving: false)
    #expect(browser.openDocuments.isEmpty)
    #expect(browser.editors["src/main.rs"] == nil)
    await browser.open(.file(path: "assets/logo.png", line: nil))
    #expect(browser.editors["assets/logo.png"] == nil, "images are not editable")
  }

  @Test("selections and lines become spans with character offsets and line ranges")
  func spans() throws {
    let text = "é one\ntwo three\nfour\n"
    let start = try #require(text.range(of: "one"))
    let end = try #require(text.range(of: "three"))
    let span = try #require(
      FileTextSpan.selection(start.lowerBound..<end.upperBound, in: text, path: "a.txt"))
    #expect(span.start == 2)
    #expect(span.end == 15)
    #expect(span.firstLine == 1)
    #expect(span.lastLine == 2)
    #expect(span.reference == "a.txt:1-2")
    #expect(span.linesTitle == "lines 1-2")
    let wholeLine = try #require(text.range(of: "four\n"))
    #expect(FileTextSpan.selection(wholeLine, in: text, path: "a.txt")?.lastLine == 3)
    let lineBreak = try #require(text.range(of: "\n"))
    #expect(FileTextSpan.selection(lineBreak, in: text, path: "a.txt") == nil)

    let line = try #require(FileTextSpan.line(2, in: "a\r\nbc\r\n", path: "w.txt"))
    #expect(line.start == 3)
    #expect(line.end == 5)
    #expect(line.text == "bc")
    #expect(line.reference == "w.txt:2-2")
    #expect(FileTextSpan.line(9, in: text, path: "a.txt") == nil)
  }

  @Test("comments are left on a span and listed by line")
  func comments() async throws {
    let source = SampleWorkspaceDataSource()
    let browser = WorkspaceBrowserModel(source: source)
    await browser.open(.file(path: "src/main.rs", line: nil))
    let text = WorkspaceSamples.mainText
    let span = try #require(FileTextSpan.line(2, in: text, path: "src/main.rs"))
    try await browser.addComment("Why here?", on: span)
    #expect(source.requests.contains("comment src/main.rs:2-2"))
    #expect(browser.comments["src/main.rs"]?.value?.map(\.line) == [2])
  }

  @Test("sorting keeps folders first and orders files by the chosen key")
  func sorting() {
    let now = Date(timeIntervalSince1970: 1_000)
    let entries = [
      WorkspaceEntry(path: "c.rs", kind: .file, modifiedAt: now),
      WorkspaceEntry(path: "a.txt", kind: .file, size: 10, modifiedAt: now.addingTimeInterval(-5)),
      WorkspaceEntry(path: "z", kind: .directory),
      WorkspaceEntry(path: "b.md", kind: .file, size: 30),
    ]
    let order = { (sort: FileTreeSort) in sort.sorted(entries).map(\.path) }
    #expect(order(.name) == ["z", "a.txt", "b.md", "c.rs"])
    #expect(order(.size) == ["z", "b.md", "a.txt", "c.rs"])
    #expect(order(.lastEdited) == ["z", "c.rs", "a.txt", "b.md"])
    #expect(order(.type) == ["z", "b.md", "c.rs", "a.txt"])
  }
}
