import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentWorkspaceUI
import Testing

@testable import OmnigentStores

/// The file views: search, saving over someone else's change, comments, and each failure.
@MainActor
@Suite("Workspace files", .timeLimit(.minutes(1)))
struct WorkspaceStoreWriteTests {
  private let base = "/v1/sessions/conv_a/resources/environments/default"

  private func workspace(_ server: RouteServer) async throws -> WorkspaceStore {
    try #require(try await connectedStore(server).workspace("conv_a"))
  }

  private func failure(_ call: () async throws -> Void) async -> WorkspaceFailure? {
    do {
      try await call()
      return nil
    } catch {
      return error as? WorkspaceFailure
    }
  }

  private func comment(_ id: String, author: String?, status: String = "draft") -> String {
    let creator = author.map { #","created_by":"\#($0)""# } ?? ""
    return
      #"{"id":"\#(id)","conversation_id":"conv_a","path":"a.rs","body":"look","status":"\#(status)","start_index":0,"anchor_content":"let","created_at":100\#(creator)}"#
  }

  @Test("Every read reports what the server refused, in the view's words")
  func refusedReads() async throws {
    let server = RouteServer()
    server.route(
      "\(base)/changes",
      .json(#"{"error":{"message":"Read-only share"}}"#, status: 403))
    let workspace = try await workspace(server)
    let changes = await failure { _ = try await workspace.changes() }
    #expect(changes?.kind == .forbidden)
    #expect(changes?.message.isEmpty == false)

    let missing = await failure { _ = try await workspace.fileContents("gone.txt") }
    #expect(missing != nil)
    #expect(await failure { _ = try await workspace.listDirectory("src", after: "x") } != nil)
    #expect(
      await failure { _ = try await workspace.searchPaths("q", include: "", exclude: "") } != nil)
    let query = OmnigentWorkspaceUI.ContentSearchQuery(
      query: "q", caseSensitive: false, regex: false, include: "", exclude: "")
    #expect(await failure { _ = try await workspace.searchContent(query) } != nil)
    #expect(await failure { _ = try await workspace.comments(on: "a.rs", text: "") } != nil)
    #expect(await failure { _ = try await workspace.save("a.rs", text: "x", base: nil) } != nil)
    #expect(await failure { try await workspace.updateComment("c1", body: "x", open: nil) } != nil)
    #expect(await failure { try await workspace.deleteComment("c1") } != nil)
    #expect(await failure { try await workspace.sendCommentsToAgent(["c1"]) } != nil)
    let span = FileTextSpan(path: "a.rs", start: 0, end: 3, firstLine: 1, lastLine: 1, text: "let")
    #expect(await failure { try await workspace.addComment("x", on: span) } != nil)

    await workspace.loadEnvironment()
    #expect(workspace.lastError != nil)
    #expect(workspace.absoluteLocation(of: "a.rs") == nil, "no root yet")
  }

  @Test("A failure outside the workspace maps by what it needs")
  func failureKinds() {
    let signedOut = CoreError.Terminal(
      kind: .runnerUnavailable, message: "sign in", requiresSignIn: true)
    #expect(WorkspaceStore.failure(signedOut).kind == .notConnected)
    #expect(WorkspaceStore.failure(.InvalidState(message: "odd")).kind == .server)
    #expect(WorkspaceStore.failure(.InvalidState(message: "odd")).message == "odd")
  }

  @Test("A file search reads matches and says when it was cut short")
  func pathSearch() async throws {
    let server = RouteServer()
    server.route("\(base)/search", .json(try recorded("workspace/recorded-search-root.json")))
    let workspace = try await workspace(server)
    let result = try await workspace.searchPaths("main", include: "*.rs, *.md", exclude: "")
    #expect(!result.entries.isEmpty)
    let request = try #require(server.requests(to: "\(base)/search").last)
    #expect(request.url.contains("include"))
  }

  @Test("A content search groups lines by file and keeps the match's range")
  func contentSearch() async throws {
    let server = RouteServer()
    server.route(
      "\(base)/content-search",
      .json(
        #"{"matches":[{"path":"b.rs","line":2,"column":1,"text":"let x","match_start":4,"match_end":5},{"path":"a.rs","line":1,"column":1,"text":"let y","match_start":4,"match_end":5},{"path":"a.rs","line":3,"column":1,"text":"x","match_start":0,"match_end":1}],"truncated":true,"warning":"partial"}"#
      ))
    let workspace = try await workspace(server)
    let result = try await workspace.searchContent(
      OmnigentWorkspaceUI.ContentSearchQuery(
        query: "x", caseSensitive: true, regex: true, include: "*.rs", exclude: "b*"))
    #expect(result.files.map(\.path) == ["a.rs", "b.rs"])
    #expect(result.files.first?.matches.map(\.line) == [1, 3])
    #expect(result.files.last?.matches.first?.match.start == 4)
    #expect(result.truncated)
    #expect(result.warning == "partial")
  }

  @Test("Saving goes through; someone else's change is a conflict with their text")
  func saves() async throws {
    let server = RouteServer()
    let file = "\(base)/filesystem/notes.md"
    server.route(
      file, method: "GET",
      .json(try recorded("workspace/recorded-file-text.json")))
    server.route(file, method: "PUT", .json(#"{"created":false}"#))
    let workspace = try await workspace(server)

    #expect(try await workspace.save("notes.md", text: "new", base: nil) == .saved)
    let result = try await workspace.save("notes.md", text: "mine", base: "not what is there")
    guard case .conflict(let latest) = result else {
      Issue.record("result: \(result)")
      return
    }
    #expect(latest?.isEmpty == false)
    #expect(server.requests(to: file, method: "PUT").count == 1, "a conflict writes nothing")
  }

  @Test("Bytes come back as the server sent them")
  func fileBytes() async throws {
    let server = RouteServer()
    server.route(
      "\(base)/filesystem/src/main.rs", .json(try recorded("workspace/recorded-file-text.json")))
    let workspace = try await workspace(server)
    let contents = try await workspace.fileContents("src/main.rs")
    #expect(!contents.data.isEmpty)
    #expect(contents.path == "src/main.rs")
  }

  @Test(
    "A diff keeps how the file changed",
    arguments: [
      ("recorded-diff-created.json", "src/new_file.rs", OmnigentWorkspaceUI.FileChangeKind.added),
      ("recorded-diff-deleted.json", "src/util/mod.rs", .deleted),
      ("recorded-diff-modified.json", "src/main.rs", .modified),
    ])
  func diffs(fixture: String, path: String, change: OmnigentWorkspaceUI.FileChangeKind)
    async throws
  {
    let server = RouteServer()
    server.route("\(base)/diff/\(path)", .json(try recorded("workspace/\(fixture)")))
    let workspace = try await workspace(server)
    let diff = try await workspace.diff(path)
    #expect(diff.change == change)
    #expect(!diff.hunks.isEmpty)
    #expect(!diff.splitRows.isEmpty)
  }

  @Test("Only the viewer's comments and unattributed ones can be changed")
  func comments() async throws {
    let server = RouteServer()
    let list = [
      comment("c1", author: "ada"), comment("c2", author: "bob"), comment("c3", author: nil),
    ]
    server.route(
      "/v1/sessions/conv_a/comments",
      .json("[\(list.joined(separator: ","))]"))
    let workspace = try await workspace(server)
    workspace.viewerID = { "ada" }
    let rows = try await workspace.comments(on: "a.rs", text: "let x = 1")
    #expect(rows.map(\.id) == ["c1", "c2", "c3"])
    #expect(rows.map(\.canModify) == [true, false, true])
    #expect(rows.first?.createdAt == Date(timeIntervalSince1970: 100))
    #expect(rows.first?.isOpen == true)
    #expect(try await workspace.comments(on: "other.rs", text: "").isEmpty)
  }

  @Test("Comment writes reach the server")
  func commentWrites() async throws {
    let server = RouteServer()
    let one = HttpResponse.json(comment("c1", author: "ada"))
    server.route("/v1/sessions/conv_a/comments", method: "POST", one)
    server.route("/v1/sessions/conv_a/comments/c1", method: "PATCH", one)
    server.route("/v1/sessions/conv_a/comments/c1", method: "DELETE", .json("", status: 204))
    server.route(
      "/v1/sessions/conv_a/comments/send", method: "POST",
      .json(#"{"formatted_message":"look","queued":true}"#))
    let workspace = try await workspace(server)
    try await workspace.addComment(
      "look",
      on: FileTextSpan(path: "a.rs", start: 0, end: 3, firstLine: 1, lastLine: 1, text: "let"))
    try await workspace.updateComment("c1", body: "more", open: false)
    let patch = try #require(
      server.requests(to: "/v1/sessions/conv_a/comments/c1", method: "PATCH").last)
    #expect(try server.body(of: patch)["body"] as? String == "more")
    try await workspace.deleteComment("c1")
    #expect(server.requests(to: "/v1/sessions/conv_a/comments/c1", method: "DELETE").count == 1)
  }

  @Test("An invalidation for this environment bumps the revision; another's does nothing")
  func invalidations() async throws {
    let workspace = try await workspace(RouteServer())
    workspace.changedFilesInvalidated(environmentID: "other", update: .unavailable(message: "m"))
    #expect(workspace.changesRevision == 0)
    #expect(workspace.lastChangedFiles == nil)
    workspace.changedFilesInvalidated(environmentID: "default", update: .unavailable(message: "m"))
    #expect(workspace.changesRevision == 1)
    #expect(workspace.lastChangedFiles == .unavailable(message: "m"))
  }

  @Test("A path outside the root is refused and remembered")
  func absolutePaths() async throws {
    let server = RouteServer()
    server.route(base, .json(try recorded("workspace/recorded-environment-default.json")))
    let workspace = try await workspace(server)
    await workspace.loadEnvironment()
    #expect(workspace.lastError == nil)
    #expect(workspace.absoluteLocation(of: "../secret") == nil)
    #expect(workspace.lastError != nil)
  }
}

/// Each record the core reports has a view record: nothing falls through.
@Suite("Workspace mapping")
struct WorkspaceMappingTests {
  @Test(
    "Failure kinds keep their meaning",
    arguments: [
      (WorkspaceErrorKind.notConnected, WorkspaceFailure.Kind.notConnected),
      (.invalidInput, .invalidInput), (.notFound, .notFound), (.notChanged, .notChanged),
      (.unavailable, .unavailable), (.forbidden, .forbidden), (.runnerOffline, .runnerOffline),
      (.searchDisabled, .searchDisabled), (.searchFailed, .searchFailed), (.server, .server),
    ])
  func kinds(core: WorkspaceErrorKind, view: WorkspaceFailure.Kind) {
    #expect(WorkspaceMapping.kind(core) == view)
  }

  @Test("Entry kinds, including one this client doesn't know")
  func entryKinds() {
    func kind(_ kind: OmnigentCoreFFI.WorkspaceEntryKind) -> OmnigentWorkspaceUI.WorkspaceEntryKind
    {
      WorkspaceMapping.entry(
        OmnigentCoreFFI.WorkspaceEntry(
          path: "a", name: "a", kind: kind, size: 1, modifiedAt: 2)
      ).kind
    }
    #expect(kind(.file) == .file)
    #expect(kind(.directory) == .directory)
    #expect(kind(.symlink) == .symlink)
    #expect(kind(.other) == .other)
    #expect(kind(.unknown(value: "door")) == .unknown("door"))
    #expect(WorkspaceMapping.date(nil) == nil)
    #expect(WorkspaceMapping.date(5) == Date(timeIntervalSince1970: 5))
  }

  @Test("Change statuses")
  func statuses() {
    #expect(WorkspaceMapping.status(.created) == .created)
    #expect(WorkspaceMapping.status(.modified) == .modified)
    #expect(WorkspaceMapping.status(.deleted) == .deleted)
    #expect(WorkspaceMapping.status(.unknown(value: "x")) == .unknown("x"))
  }

  @Test("Image formats")
  func imageFormats() {
    let formats: [(OmnigentCoreFFI.ImageFormat, OmnigentWorkspaceUI.ImageFormat)] = [
      (.png, .png), (.jpeg, .jpeg), (.gif, .gif), (.webp, .webp), (.bmp, .bmp), (.tiff, .tiff),
      (.heic, .heic), (.ico, .ico),
    ]
    #expect(formats.allSatisfy { WorkspaceMapping.imageFormat($0.0) == $0.1 })
  }

  @Test("Previews: image, binary with why, text with its line ending")
  func previews() {
    let data = Data([1])
    #expect(
      WorkspaceMapping.preview(.image(format: .png, data: data)) == .image(format: .png, data: data)
    )
    #expect(
      WorkspaceMapping.preview(.binary(reason: .notText, byteCount: 0)) == .binary(reason: .notText)
    )
    #expect(
      WorkspaceMapping.preview(.binary(reason: .nulBytes, byteCount: 0))
        == .binary(reason: .nulBytes))
    #expect(
      WorkspaceMapping.preview(.binary(reason: .truncatedImage, byteCount: 0))
        == .binary(reason: .truncatedImage))
    let endings: [(OmnigentCoreFFI.LineEnding, OmnigentWorkspaceUI.LineEnding)] = [
      (.lf, .lf), (.crLf, .crlf), (.mixed, .mixed),
    ]
    for (core, view) in endings {
      let text = OmnigentCoreFFI.TextPreview(
        text: "x", lineCount: 1, lineEnding: core, hasBom: false, language: .swift,
        skipHighlighting: false, clipped: false, serverTruncated: false)
      #expect(WorkspaceMapping.textPreview(text).lineEnding == view)
      #expect(WorkspaceMapping.textPreview(text).language == .swift)
    }
  }

  @Test("A renamed or copied file keeps both paths, and each side of a split row its kind")
  func diffRecords() {
    func diff(_ change: OmnigentCoreFFI.FileChangeKind) -> OmnigentWorkspaceUI.FileDiff {
      WorkspaceMapping.fileDiff(
        OmnigentCoreFFI.FileDiff(
          oldPath: "old", newPath: "new", change: change, hunks: [], splitRows: [],
          added: 0, removed: 0, binary: false, approximate: false, tooLarge: false,
          displayPath: "new", isIdentical: false))
    }
    #expect(diff(.renamed).change == .renamed)
    #expect(diff(.copied).change == .copied)
    #expect(diff(.renamed).oldPath == "old")
    #expect(WorkspaceMapping.lineKind(.context) == .context)
    #expect(WorkspaceMapping.lineKind(.added) == .added)
    #expect(WorkspaceMapping.lineKind(.removed) == .removed)
    #expect(WorkspaceMapping.cell(nil) == nil)
    let cell = WorkspaceMapping.cell(
      OmnigentCoreFFI.SplitCell(
        kind: .added, number: 3, text: "x",
        changed: OmnigentCoreFFI.TextRange(start: 1, end: 2)))
    #expect(cell?.changed == OmnigentWorkspaceUI.TextRange(start: 1, end: 2))
    #expect(cell?.number == 3)
  }

  @Test("Syntax languages")
  func languages() {
    let table: [(OmnigentCoreFFI.SyntaxLanguage, OmnigentWorkspaceUI.SyntaxLanguage)] = [
      (.bash, .bash), (.c, .c), (.cpp, .cpp), (.cSharp, .csharp), (.css, .css),
      (.dockerfile, .dockerfile), (.go, .go), (.html, .html), (.java, .java),
      (.javaScript, .javascript), (.json, .json), (.kotlin, .kotlin), (.makefile, .makefile),
      (.markdown, .markdown), (.objectiveC, .objectiveC), (.php, .php), (.python, .python),
      (.ruby, .ruby), (.rust, .rust), (.scala, .scala), (.sql, .sql), (.swift, .swift),
      (.toml, .toml), (.typeScript, .typescript), (.xml, .xml), (.yaml, .yaml),
    ]
    for (core, view) in table { #expect(WorkspaceMapping.language(core) == view) }
  }
}
