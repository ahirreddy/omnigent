import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentWorkspaceUI
import Testing

@testable import OmnigentStores

/// Downloads, video reads and chapters through the core, as main's runner serves them.
@MainActor
@Suite("Workspace media", .timeLimit(.minutes(1)))
struct WorkspaceStoreMediaTests {
  private let base = "/v1/sessions/conv_a/resources/environments/default/filesystem"

  private func workspace(_ server: RouteServer) async throws -> WorkspaceStore {
    try #require(try await connectedStore(server).workspace("conv_a"))
  }

  /// The runner's `_fs_download` answer.
  private func download(_ body: String, status: UInt16 = 200, range: String? = nil)
    -> HttpResponse
  {
    var headers = [
      HttpHeader(name: "Content-Type", value: "video/mp4"),
      HttpHeader(name: "Content-Disposition", value: #"attachment; filename="demo.mp4""#),
    ]
    if let range { headers.append(HttpHeader(name: "Content-Range", value: range)) }
    return HttpResponse(status: status, headers: headers, body: Data(body.utf8))
  }

  @Test("A video opens without a read, then streams by range with its accepted type")
  func videoRanges() async throws {
    let server = RouteServer()
    server.route("\(base)/rec/demo.mp4", download("cde", status: 206, range: "bytes 2-4/10"))
    let workspace = try await workspace(server)
    let file = try await workspace.readFile("rec/demo.mp4")
    #expect(file.preview == .video)
    #expect(server.requests(to: "\(base)/rec/demo.mp4").isEmpty, "the envelope is never read")
    let chunk = try await workspace.readVideo("rec/demo.mp4", offset: 2, length: 3)
    #expect(chunk.data == Data("cde".utf8))
    #expect(chunk.offset == 2)
    #expect(chunk.totalLength == 10)
    #expect(chunk.videoType == "video/mp4")
    let sent = try #require(server.requests(to: "\(base)/rec/demo.mp4").last)
    #expect(sent.url.hasSuffix("?download=true"))
    #expect(sent.headers.contains { $0.name == "Range" && $0.value == "bytes=2-4" })
  }

  @Test("Download reads the whole file, past the preview's cap, and says what failed")
  func wholeDownload() async throws {
    let server = RouteServer()
    server.route("\(base)/rec/demo.mp4", download("0123456789"))
    let workspace = try await workspace(server)
    let contents = try await workspace.download("rec/demo.mp4")
    #expect(contents.data == Data("0123456789".utf8))
    #expect(!contents.truncated)
    let sent = try #require(server.requests(to: "\(base)/rec/demo.mp4").last)
    #expect(!sent.headers.contains { $0.name == "Range" })

    server.route(
      "\(base)/rec/demo.mp4",
      .json(
        #"{"error":{"code":"runner_unavailable","message":"Session runner does not support file downloads; restart the session"}}"#,
        status: 503))
    do {
      _ = try await workspace.download("rec/demo.mp4")
      Issue.record("an old runner's refusal was taken for the file")
    } catch {
      #expect(error.kind == .runnerOffline)
    }
  }

  @Test("A PDF previews whole, or says the server cut it")
  func pdfPreview() async throws {
    let server = RouteServer()
    server.route(
      "\(base)/docs/a.pdf",
      .json(
        #"{"object":"session.environment.filesystem.file_content","path":"docs/a.pdf","content_type":"application/pdf","bytes":8,"truncated":true,"encoding":"base64","content":"JVBERi0xLjQ="}"#
      ))
    let workspace = try await workspace(server)
    let file = try await workspace.readFile("docs/a.pdf")
    #expect(file.preview == .pdf(data: Data("%PDF-1.4".utf8), truncated: true))
  }

  @Test("A recording's chapters come from its .chapters.vtt file; none without one")
  func chapters() async throws {
    let server = RouteServer()
    let vtt =
      "WEBVTT\\n\\n00:00.000 --> 00:04.500\\nSign in\\n\\n00:04.500 --> 00:09.000\\nOpen the settings\\n"
    server.route(
      "\(base)/rec/demo.mp4.chapters.vtt",
      .json(
        #"{"object":"session.environment.filesystem.file_content","path":"rec/demo.mp4.chapters.vtt","content_type":"text/vtt","bytes":80,"truncated":false,"encoding":"utf-8","content":"\#(vtt)"}"#
      ))
    let workspace = try await workspace(server)
    let found = await workspace.videoChapters("rec/demo.mp4")
    #expect(found.file == "rec/demo.mp4.chapters.vtt")
    #expect(found.chapters.map(\.title) == ["Sign in", "Open the settings"])
    #expect(found.chapters.first?.end == 4.5)
    let none = await workspace.videoChapters("rec/other.mp4")
    #expect(none == .none)
  }
}
