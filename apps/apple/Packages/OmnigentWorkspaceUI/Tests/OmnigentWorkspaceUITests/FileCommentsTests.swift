import Foundation
import Testing

@testable import OmnigentWorkspaceUI

@Suite("File comments")
struct FileCommentsTests {
  private func browserWithComment() async throws -> (
    SampleWorkspaceDataSource, WorkspaceBrowserModel
  ) {
    let source = SampleWorkspaceDataSource()
    let browser = WorkspaceBrowserModel(source: source)
    await browser.open(.file(path: "src/main.rs", line: nil))
    let span = try #require(
      FileTextSpan.line(2, in: WorkspaceSamples.mainText, path: "src/main.rs"))
    try await browser.addComment("Why here?", on: span)
    return (source, browser)
  }

  private func comments(_ browser: WorkspaceBrowserModel) -> [FileCommentLine] {
    browser.comments["src/main.rs"]?.value ?? []
  }

  @Test("a comment is edited, resolved, reopened and deleted, and the list follows")
  func lifecycle() async throws {
    let (source, browser) = try await browserWithComment()
    let id = try #require(comments(browser).first?.id)
    try await browser.updateComment(id, on: "src/main.rs", body: "Why here, not in lib?")
    #expect(comments(browser).first?.body == "Why here, not in lib?")
    try await browser.updateComment(id, on: "src/main.rs", open: false)
    #expect(comments(browser).first?.isOpen == false)
    try await browser.updateComment(id, on: "src/main.rs", open: true)
    #expect(comments(browser).first?.isOpen == true)
    try await browser.deleteComment(id, on: "src/main.rs")
    #expect(comments(browser).isEmpty)
    #expect(source.requests.contains("delete-comment \(id)"))
  }

  @Test("Address All sends only the open comments; a failed send leaves them open")
  func addressAll() async throws {
    let (source, browser) = try await browserWithComment()
    let span = try #require(
      FileTextSpan.line(3, in: WorkspaceSamples.mainText, path: "src/main.rs"))
    try await browser.addComment("And this?", on: span)
    let ids = comments(browser).map(\.id)
    try await browser.updateComment(ids[1], on: "src/main.rs", open: false)

    source.failures["#send"] = WorkspaceFailure(.server, message: "The host is offline.")
    await #expect(throws: WorkspaceFailure.self) {
      try await browser.sendOpenComments(on: "src/main.rs")
    }
    #expect(comments(browser).filter(\.isOpen).map(\.id) == [ids[0]])

    source.failures["#send"] = nil
    try await browser.sendOpenComments(on: "src/main.rs")
    #expect(source.requests.last { $0.hasPrefix("send-comments") } == "send-comments \(ids[0])")
    #expect(comments(browser).allSatisfy { !$0.isOpen })
  }

  @Test("only open comments mark lines")
  func markedLines() {
    let open = FileCommentLine(id: "a", line: 2, body: "open")
    let sent = FileCommentLine(id: "b", line: 3, body: "sent", isOpen: false)
    let review = FileReviewContext(
      comments: [open, sent], canComment: true, add: { _, _ in }, reveal: { _ in },
      attach: nil, ask: nil)
    #expect(review.commentsByLine.keys.sorted() == [2])
    #expect(review.openComments.map(\.id) == ["a"])
  }

  @Test("comment times read as the web's: today, yesterday, else the date")
  func times() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let today = FileCommentTime.label(now.addingTimeInterval(-60), now: now, calendar: calendar)
    #expect(today.hasSuffix(" Today"))
    let yesterday = FileCommentTime.label(
      now.addingTimeInterval(-86_400), now: now, calendar: calendar)
    #expect(yesterday.hasSuffix(" Yesterday"))
    let older = FileCommentTime.label(
      now.addingTimeInterval(-9 * 86_400), now: now, calendar: calendar)
    #expect(!older.contains("Today") && !older.contains("Yesterday"))
  }

  @Test("a selection in a CRLF file counts each \\r in its offsets and anchor")
  func crlfSelection() throws {
    // The editor shows "ab\r\ncd\r\nef" as "ab\ncd\nef".
    let text = "ab\ncd\nef"
    let range = try #require(text.range(of: "cd\ne"))
    let span = try #require(FileTextSpan.selection(range, in: text, path: "w.txt", crlf: true))
    #expect(span.start == 4)
    #expect(span.end == 9)
    #expect(span.text == "cd\r\ne")
    #expect(span.firstLine == 2)
    #expect(span.lastLine == 3)
    let raw = "ab\r\ncd\r\nef"
    let scalars = Array(raw.unicodeScalars)
    #expect(String(String.UnicodeScalarView(scalars[4..<9])) == span.text)
  }

  @Test("saving everything saves each unsaved edit; discarding reverts them")
  func saveAndDiscardAll() async throws {
    let source = SampleWorkspaceDataSource()
    let browser = WorkspaceBrowserModel(source: source)
    await browser.open(.file(path: "src/main.rs", line: nil))
    let editor = try #require(browser.editors["src/main.rs"])
    editor.autosaveDelay = nil
    editor.text = "fn main() {}\n"
    #expect(UnsavedFileEdits.paths.contains("src/main.rs"))
    #expect(await browser.saveAll().isEmpty)
    #expect(source.savedTexts["src/main.rs"] == "fn main() {}\n")

    editor.text = "changed again\n"
    let revision = editor.textRevision
    browser.discardAll()
    #expect(editor.text == "fn main() {}\n")
    #expect(editor.textRevision == revision + 1, "the text view reloads")
    #expect(browser.unsavedPaths.isEmpty)

    editor.text = "failing\n"
    source.failures["#save"] = WorkspaceFailure(.forbidden, message: "Read-only")
    #expect(await browser.saveAll() == ["src/main.rs"])
    #expect(
      UnsavedFileEdits.title(for: ["src/main.rs"]) == "Save changes to \u{201C}main.rs\u{201D}?")
    #expect(UnsavedFileEdits.title(for: ["a", "b"]) == "Save changes to 2 files?")
  }
}
