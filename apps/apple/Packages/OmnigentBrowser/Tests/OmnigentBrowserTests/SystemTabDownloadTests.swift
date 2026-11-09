import Foundation
import OmnigentViewTesting
import Testing
import WebKit

@testable import OmnigentBrowser

@MainActor
@Suite("System tab downloads", .serialized)
struct SystemTabDownloadTests {
  private func tempDestination() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "system-download-\(UUID().uuidString).txt")
  }

  /// Starts a real download of `text` from a data: address, tracked by the tab. WebKit can drop
  /// the reply while the network process changes over, so an unanswered start is tried again.
  private func startDownload(_ fixture: SystemTabFixture, text: String) async throws -> WKDownload {
    let encoded = Data(text.utf8).base64EncodedString()
    let url = try testURL("data:text/plain;base64,\(encoded)")
    let webView = fixture.tab.webView
    for _ in 0..<3 {
      var started: WKDownload?
      Task { started = await webView.startDownload(using: URLRequest(url: url)) }
      guard try await waitUntil(timeout: .seconds(3), { started != nil }), let download = started
      else {
        continue
      }
      fixture.tab.webView(
        webView, navigationAction: FakeNavigationAction(url: url), didBecome: download)
      return download
    }
    throw BrowserError.downloadFailed("WebKit never started the download.")
  }

  @Test("a download asks where to save, then finishes with the file there")
  func savesAFile() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    let destination = tempDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    _ = try await startDownload(fixture, text: "file contents")
    let asked = try await waitUntil { !fixture.delegate.requested.isEmpty }
    #expect(asked)
    guard case .download(let prompt)? = fixture.delegate.requested.last else {
      Issue.record("expected a download prompt")
      return
    }
    #expect(prompt.mimeType == "text/plain")
    prompt.save(to: destination)
    #expect(fixture.tab.state.pendingPrompts.isEmpty)
    let record = try #require(fixture.delegate.started.first)
    #expect(record.destination == destination)
    #expect(record.engine == .system)
    #expect(try await waitUntil { record.state == .complete })
    #expect(try String(contentsOf: destination, encoding: .utf8) == "file contents")
    #expect(fixture.tab.downloadTrackers.isEmpty)
  }

  @Test("declining a download saves nothing and lets go of it")
  func declined() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    _ = try await startDownload(fixture, text: "unwanted")
    #expect(try await waitUntil { !fixture.delegate.requested.isEmpty })
    guard case .download(let prompt)? = fixture.delegate.requested.last else {
      Issue.record("expected a download prompt")
      return
    }
    prompt.cancel()
    #expect(fixture.delegate.started.isEmpty)
    #expect(fixture.tab.downloadTrackers.isEmpty)
    #expect(fixture.tab.state.pendingPrompts.isEmpty)
  }

  /// A tracker holding a saved record, ready for what happens next.
  private struct SavedDownload {
    let tracker: SystemDownloadTracker
    let record: BrowserDownload
    let download: WKDownload
  }

  private func savedTracker(_ fixture: SystemTabFixture, length: Int64) async throws
    -> SavedDownload
  {
    let download = try await startDownload(fixture, text: "x")
    let tracker = SystemDownloadTracker(tab: fixture.tab, download: download)
    let url = try testURL("https://a.example/file.zip")
    let response = URLResponse(
      url: url, mimeType: "application/zip", expectedContentLength: Int(length),
      textEncodingName: nil)
    let ignoreDestination: @MainActor @Sendable (URL?) -> Void = { _ in }
    tracker.download(
      download, decideDestinationUsing: response, suggestedFilename: "file.zip",
      completionHandler: ignoreDestination)
    guard case .download(let prompt)? = fixture.delegate.requested.last else {
      throw BrowserError.downloadFailed("no prompt")
    }
    #expect(prompt.suggestedName == "file.zip")
    #expect(prompt.totalBytes == (length >= 0 ? length : nil))
    prompt.save(to: tempDestination())
    let record = try #require(fixture.delegate.started.last)
    return SavedDownload(tracker: tracker, record: record, download: download)
  }

  @Test("a failed download shows why; a cancelled one shows as cancelled, not failed")
  func failures() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    let failing = try await savedTracker(fixture, length: 10)
    failing.tracker.download(
      failing.download, didFailWithError: BrowserError.downloadFailed("disk full"), resumeData: nil)
    guard case .failed = failing.record.state else {
      Issue.record("expected failed, got \(failing.record.state)")
      return
    }

    let cancelling = try await savedTracker(fixture, length: -1)
    #expect(cancelling.record.totalBytes == nil)
    let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    cancelling.tracker.download(cancelling.download, didFailWithError: cancelled, resumeData: nil)
    #expect(cancelling.record.state == .cancelled)
  }

  @Test("a download that fails before it has a place to go is reported on the tab")
  func failsBeforeSaving() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    let download = try await startDownload(fixture, text: "x")
    let tracker = SystemDownloadTracker(tab: fixture.tab, download: download)
    tracker.download(
      download, didFailWithError: BrowserError.downloadFailed("gone"), resumeData: nil)
    guard case .downloadFailed? = fixture.tab.state.lastError else {
      Issue.record("expected a download failure on the tab")
      return
    }
  }

  @Test("Cancel stops the download; finishing fills in the bytes")
  func cancelAndFinish() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    let saved = try await savedTracker(fixture, length: 5)
    try saved.record.cancel()
    saved.tracker.downloadDidFinish(saved.download)
    #expect(saved.record.state == .complete)
    #expect(saved.record.receivedBytes == 5)
    #expect(throws: BrowserError.self) { try saved.record.cancel() }
  }

  @Test("a download whose tab has gone is refused")
  func tabGone() async throws {
    var fixture: SystemTabFixture? = try SystemTabFixture()
    let download = try await startDownload(try #require(fixture), text: "x")
    weak let closed = fixture?.tab
    let tracker = try SystemDownloadTracker(tab: #require(closed), download: download)
    fixture?.tab.close()
    fixture = nil
    var answered = false
    var destination: URL?
    let response = URLResponse(
      url: try testURL("https://a.example/f"), mimeType: nil, expectedContentLength: 0,
      textEncodingName: nil)
    tracker.download(download, decideDestinationUsing: response, suggestedFilename: "f") {
      answered = true
      destination = $0
    }
    #expect(answered)
    #expect(destination == nil)
  }
}
