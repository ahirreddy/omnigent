import CoreGraphics
import Foundation
import SceneKit
import Testing

@testable import OmnigentWorkspaceUI

#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import PDFKit
  import SwiftUI
#endif

/// The PDF and video viewers, as the web's `PdfViewer` and `VideoPlayer` show them.
@MainActor
@Suite("PDF and video viewers", .serialized)
struct MediaViewerTests {
  @Test("zoom steps a quarter between half size and three times, and counts pages")
  func pdfToolbar() {
    #expect(PDFPreviewView.zoomedIn(1) == 1.25)
    #expect(PDFPreviewView.zoomedIn(3) == 3)
    #expect(PDFPreviewView.zoomedOut(0.5) == 0.5)
    #expect(PDFPreviewView.zoomedOut(0.75) == 0.5)
    #expect(PDFPreviewView.percent(1.25) == "125%")
    #expect(PDFPreviewView.pageCount(1) == "1 page")
    #expect(PDFPreviewView.pageCount(12) == "12 pages")
    #expect(PDFPreviewView.pageCount(0).isEmpty)
  }

  @Test("STL and OBJ models read into a scene, an STL with a plain material")
  func modelScenes() throws {
    #expect(ModelPreviewView.canRead(.stl) && ModelPreviewView.canRead(.obj))
    let obj = "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"
    #expect(ModelPreviewView.scene(Data(obj.utf8), format: .obj) != nil)
    #expect(ModelPreviewView.scene(Data("not a model".utf8), format: .obj) == nil)
    let scene = try #require(ModelPreviewView.scene(Self.binarySTL, format: .stl))
    let meshes = ModelPreviewView.meshes(in: scene)
    #expect(!meshes.isEmpty)
    #expect(meshes.first?.geometry?.materials.first?.lightingModel == .physicallyBased)
  }

  /// One triangle as binary STL: an 80-byte header, the count, then the facet.
  private static var binarySTL: Data {
    func bytes(_ word: UInt32) -> [UInt8] {
      [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: word >> UInt32($0)) }
    }
    var data = Data(count: 80)
    data.append(contentsOf: bytes(1))
    let floats: [Float32] = [0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0]
    for value in floats { data.append(contentsOf: bytes(value.bitPattern)) }
    data.append(contentsOf: [0, 0])
    return data
  }

  @Test("the HTML preview zooms through the browser's presets and stops at both ends")
  func htmlZoomSteps() {
    #expect(HTMLPreviewZoom.zoomedIn(1) == 1.1)
    #expect(HTMLPreviewZoom.zoomedOut(1) == 0.9)
    #expect(HTMLPreviewZoom.zoomedIn(1.05) == 1.1, "an off-preset zoom steps to the next preset")
    #expect(HTMLPreviewZoom.zoomedIn(5) == 5)
    #expect(HTMLPreviewZoom.zoomedOut(0.25) == 0.25)
  }

  @Test("a PDF selection is kept as fractions of its page from the top left, as the web keeps it")
  func pdfCommentGeometry() throws {
    let box = CGRect(x: 0, y: 0, width: 600, height: 800)
    let line = CGRect(x: 60, y: 600, width: 300, height: 20)
    let fraction = try #require(PDFCommentCoordinator.fraction(line, in: box))
    #expect(fraction == CGRect(x: 0.1, y: 0.225, width: 0.5, height: 0.025))
    #expect(PDFCommentCoordinator.pageRect(fraction, in: box) == line)
    #expect(PDFCommentCoordinator.fraction(.zero, in: box) == nil)
    let span = FileTextSpan.pdf("Total", mark: PdfMark(page: 3, rects: [fraction]), path: "a.pdf")
    #expect(span.linesTitle == "page 3")
  }

  @Test("chapter times read m:ss of whole seconds")
  func chapterTimes() {
    #expect(WorkspaceVideoTime.clock(0) == "0:00")
    #expect(WorkspaceVideoTime.clock(65.9) == "1:05")
    #expect(WorkspaceVideoTime.clock(3_600) == "60:00")
    #expect(WorkspaceVideoTime.clock(.nan) == "0:00")
  }

  @Test("a request asks for its range in chunks, or the first byte for the content facts")
  func loaderPlan() {
    let ranged = WorkspaceVideoLoader.Plan(start: 10, end: 20)
    #expect(ranged.length(from: 10) == 10)
    #expect(ranged.length(from: 20) == 0)
    let open = WorkspaceVideoLoader.Plan(start: 0, end: nil)
    #expect(open.length(from: 5_000_000) == WorkspaceVideoLoader.chunkLength)
    let long = WorkspaceVideoLoader.Plan(start: 0, end: 5 * WorkspaceVideoLoader.chunkLength)
    #expect(long.length(from: 0) == WorkspaceVideoLoader.chunkLength)
  }

  @Test("a chunk gives the bytes asked for, skipping the start of a whole file")
  func loaderSlice() throws {
    let part = WorkspaceVideoChunk(
      data: Data("cdef".utf8), offset: 2, totalLength: 10, videoType: "video/mp4")
    #expect(try WorkspaceVideoLoader.slice(part, from: 2, length: 3) == Data("cde".utf8))
    let whole = WorkspaceVideoChunk(
      data: Data("0123456789".utf8), offset: 0, totalLength: 10, videoType: "video/mp4")
    #expect(try WorkspaceVideoLoader.slice(whole, from: 7, length: 5) == Data("789".utf8))
    #expect(throws: WorkspaceVideoLoader.Failure.misplacedBytes) {
      try WorkspaceVideoLoader.slice(part, from: 1, length: 1)
    }
  }

  @Test("the player learns the file's uniform type and length; else the stream stops")
  func loaderFacts() throws {
    let chunk = WorkspaceVideoChunk(
      data: Data(), offset: 0, totalLength: 10, videoType: "video/mp4")
    let facts = try WorkspaceVideoLoader.facts(of: chunk)
    #expect(facts.type == "public.mpeg-4")
    #expect(facts.length == 10)
    let untyped = WorkspaceVideoChunk(data: Data(), offset: 0, totalLength: 10, videoType: nil)
    #expect(throws: WorkspaceVideoLoader.Failure.unsupportedType) {
      try WorkspaceVideoLoader.facts(of: untyped)
    }
    let unsized = WorkspaceVideoChunk(
      data: Data(), offset: 0, totalLength: nil, videoType: "video/quicktime")
    #expect(throws: WorkspaceVideoLoader.Failure.unknownLength) {
      try WorkspaceVideoLoader.facts(of: unsized)
    }
  }

  @Test("Play reads the video through the source, and a failed read says so")
  func failedPlayback() async throws {
    let playback = WorkspaceVideoPlayback()
    let reads = ReadLog()
    playback.play { offset, length throws(WorkspaceFailure) in
      reads.ranges.append((offset, length))
      throw WorkspaceFailure(.runnerOffline, message: "asleep")
    }
    #expect(playback.phase == .loading)
    let deadline = ContinuousClock.now + .seconds(20)
    while playback.phase == .loading, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(playback.phase == .failed)
    #expect(!reads.ranges.isEmpty, "the player asked the source for bytes")
    playback.stop()
    #expect(playback.phase == .idle)
    #expect(playback.player == nil)
  }

  #if os(macOS)
    /// A PDF of `pages` blank pages.
    private static func pdf(pages: Int) -> Data {
      let document = PDFDocument()
      for index in 0..<pages {
        let image = NSImage(size: NSSize(width: 120, height: 160), flipped: false) { rect in
          NSColor.white.setFill()
          rect.fill()
          return true
        }
        if let page = PDFPage(image: image) { document.insert(page, at: index) }
      }
      return document.dataRepresentation() ?? Data()
    }

    private func viewer(_ preview: FilePreview, path: String) -> OffscreenWindow<FileViewerView> {
      OffscreenWindow(
        FileViewerView(
          file: WorkspaceFile(path: path, byteCount: 100, preview: preview),
          source: SampleWorkspaceDataSource()),
        width: 700, height: 500)
    }

    @Test("a PDF shows its pages in PDFKit, with the page count and zoom")
    func pdfPages() throws {
      let screen = viewer(.pdf(data: Self.pdf(pages: 2), truncated: false), path: "docs/a.pdf")
      defer { screen.close() }
      screen.settle()
      #expect(screen.allViews.contains { $0 is PDFView })
      #expect(try screen.shows("2 pages"))
      #expect(try screen.shows("100%"))
      #expect(try screen.shows("PDF"), "the header names the kind")
    }

    @Test("a PDF the server cut, or bytes that are no PDF, say why instead")
    func pdfNotes() throws {
      let cut = viewer(.pdf(data: Data("%PDF-1.4".utf8), truncated: true), path: "big.pdf")
      defer { cut.close() }
      #expect(try cut.shows(PDFPreviewView.truncatedMessage))
      #expect(!cut.allViews.contains { $0 is PDFView })
      let broken = viewer(.pdf(data: Data("not a pdf".utf8), truncated: false), path: "x.pdf")
      defer { broken.close() }
      broken.settle()
      #expect(try broken.shows(PDFPreviewView.unreadableMessage))
    }

    @Test("a video waits for Play, offers Download, and lists its chapters")
    func videoCard() async throws {
      let source = ChapteredSource()
      var downloads: [String] = []
      let screen = OffscreenWindow(
        WorkspaceVideoView(
          path: "rec/demo.mp4", source: source, download: { downloads.append($0) }),
        width: 900, height: 600)
      defer { screen.close() }
      await screen.settleTasks()
      screen.settle()
      #expect(try screen.shows("demo.mp4"))
      #expect(try screen.shows("Play recording"))
      #expect(try screen.shows("Open the settings"))
      #expect(try screen.shows("0:05"))
      #expect(source.chapterReads == ["rec/demo.mp4"])
      #expect(downloads.isEmpty, "nothing downloads until asked")
    }
  #endif
}

/// The reads a playback made.
@MainActor
private final class ReadLog {
  var ranges: [(UInt64, UInt64)] = []
}

#if os(macOS)
  /// The sample source with a recording's chapters.
  @MainActor
  private final class ChapteredSource: WorkspaceDataSource {
    private let sample = SampleWorkspaceDataSource()
    var chapterReads: [String] = []

    // swiftlint:disable:next async_without_await
    func videoChapters(_ path: String) async -> VideoChapters {
      chapterReads.append(path)
      return VideoChapters(
        file: "\(path).chapters.vtt",
        chapters: [
          VideoChapter(time: 0, end: 5, title: "Sign in"),
          VideoChapter(time: 5, end: 9, title: "Open the settings"),
        ])
    }

    // swiftlint:disable async_without_await
    func listDirectory(_ path: String, after cursor: String?) async throws(WorkspaceFailure)
      -> DirectoryPage
    { try await sample.listDirectory(path, after: cursor) }
    func readFile(_ path: String) async throws(WorkspaceFailure) -> WorkspaceFile {
      try await sample.readFile(path)
    }
    func searchPaths(_ query: String, include: String, exclude: String)
      async throws(WorkspaceFailure) -> PathSearchResult
    { try await sample.searchPaths(query, include: include, exclude: exclude) }
    func searchContent(_ query: ContentSearchQuery) async throws(WorkspaceFailure)
      -> ContentSearchResult
    { try await sample.searchContent(query) }
    func changes() async throws(WorkspaceFailure) -> ChangesList { try await sample.changes() }
    func diff(_ path: String) async throws(WorkspaceFailure) -> FileDiff {
      try await sample.diff(path)
    }
    func absoluteLocation(of path: String) -> String? { nil }
    func save(_ path: String, text: String, base: String?) async throws(WorkspaceFailure)
      -> FileSaveResult
    { try await sample.save(path, text: text, base: base) }
    func comments(on path: String, text: String) async throws(WorkspaceFailure)
      -> [FileCommentLine]
    { [] }
    func addComment(_ body: String, on span: FileTextSpan) async throws(WorkspaceFailure) {}
    // swiftlint:disable:next discouraged_optional_boolean
    func updateComment(_ id: String, body: String?, open: Bool?) async throws(WorkspaceFailure) {}
    func deleteComment(_ id: String) async throws(WorkspaceFailure) {}
    func sendCommentsToAgent(_ ids: [String]) async throws(WorkspaceFailure) {}
    // swiftlint:enable async_without_await
  }
#endif
