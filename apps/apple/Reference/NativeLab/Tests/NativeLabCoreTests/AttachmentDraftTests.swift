import Foundation
import XCTest

@testable import NativeLabCore

@MainActor
final class AttachmentDraftTests: XCTestCase {
  private let key = AttachmentDraftKey(scope: "server/account", sessionID: "session_a")

  func testSupportedTypesExactCapsAndFilenameValidation() throws {
    for (filename, declared, limit) in [
      ("a.png", "image/png", 5), ("a.pdf", "application/pdf", 20),
      ("a.txt", "text/plain", 10), ("a.ts", "video/mp2t", 10),
      ("a.csv", "application/vnd.ms-excel", 10), (".env", "", 10),
      ("a.ipynb", "application/x-ipynb+json", 10),
    ] {
      let bytes = limit * 1_024 * 1_024
      let accepted = try AttachmentUploadFile(
        filename: filename, mediaType: declared, data: Data(repeating: 1, count: bytes))
      XCTAssertEqual(accepted.data.count, bytes)
      XCTAssertThrowsError(
        try AttachmentUploadFile(
          filename: filename, mediaType: declared, data: Data(repeating: 1, count: bytes + 1))
      ) {
        XCTAssertEqual($0 as? AttachmentUploadError, .tooLarge(bytes))
      }
    }
    for name in ["a.zip", "a.docx", "a.xlsx", "a.pptx", "a.mp4", "a.mp3", "unknown"] {
      XCTAssertThrowsError(try AttachmentUploadFile(filename: name, data: Data())) {
        XCTAssertEqual($0 as? AttachmentUploadError, .unsupportedType)
      }
    }
    for name in ["", "../a.txt", "a\r\n.txt", "a\\b.txt"] {
      XCTAssertThrowsError(try AttachmentUploadFile(filename: name, data: Data()))
    }
    XCTAssertThrowsError(
      try AttachmentUploadFile(
        filename: "a.png", mediaType: "image/png\r\nBad: value", data: Data()))
  }

  func testFileReaderRejectsOversizeFoldersAndLinksBeforeBuffering() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("notes.txt")
    try Data("contents".utf8).write(to: file)
    XCTAssertEqual(try AttachmentUploadFile.read(contentsOf: file).data, Data("contents".utf8))
    let link = directory.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    XCTAssertThrowsError(try AttachmentUploadFile.read(contentsOf: link))
    XCTAssertThrowsError(
      try AttachmentUploadFile.read(contentsOf: directory, filename: "directory.txt"))
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 10 * 1_024 * 1_024 + 1)
    try handle.close()
    XCTAssertThrowsError(try AttachmentUploadFile.read(contentsOf: file)) {
      XCTAssertEqual($0 as? AttachmentUploadError, .tooLarge(10 * 1_024 * 1_024))
    }
  }

  func testDraftCountAndAggregateByteLimits() throws {
    let store = AttachmentDraftStore()
    let small = try file()
    for _ in 0..<8 { try store.add(small, to: key) }
    XCTAssertThrowsError(try store.add(small, to: key))
    let big = try AttachmentUploadFile(
      filename: "large.pdf", data: Data(repeating: 0, count: 20 * 1_024 * 1_024))
    let other = AttachmentDraftKey(scope: key.scope, sessionID: "other")
    try store.add(big, to: other)
    XCTAssertThrowsError(try store.add(big, to: other))
    for index in 0..<3 {
      try store.add(big, to: AttachmentDraftKey(scope: key.scope, sessionID: "big_\(index)"))
    }
    XCTAssertThrowsError(
      try store.add(big, to: AttachmentDraftKey(scope: key.scope, sessionID: "over_global")))
  }

  func testSuccessfulUploadIsReusedOnExplicitSendRetryAndScopedToSession() async throws {
    let store = AttachmentDraftStore()
    let counter = UploadCounter()
    let id = try store.add(file(), to: key)
    await store.upload(id, in: key, using: counter.uploader)
    await store.upload(id, in: key, using: counter.uploader)
    let calls = await counter.count
    XCTAssertEqual(calls, 1)
    let first = try store.beginSubmission(in: key)
    XCTAssertThrowsError(try store.beginSubmission(in: key))
    store.remove(id, from: key)
    XCTAssertEqual(store.draft(for: key).items.count, 1)
    store.finishSubmission(first, outcome: .rejected)
    XCTAssertEqual(store.draft(for: key).items.first?.file.data, Data("retained bytes".utf8))
    let retry = try store.beginSubmission(in: key)
    XCTAssertEqual(retry.attachments, first.attachments)
    store.finishSubmission(retry, outcome: .accepted)
    XCTAssertFalse(store.draft(for: key).hasAttachments)
    let other = AttachmentDraftKey(scope: "other/account", sessionID: key.sessionID)
    XCTAssertFalse(store.draft(for: other).hasAttachments)
  }

  func testAcceptedSnapshotOnlyRemovesCapturedFilesEvenAfterScopeSwitch() async throws {
    let store = AttachmentDraftStore()
    let counter = UploadCounter()
    let firstID = try store.add(file(), to: key)
    await store.upload(firstID, in: key, using: counter.uploader)
    let batch = try store.beginSubmission(in: key)
    let addedLater = try store.add(file(name: "later.txt"), to: key)
    let other = AttachmentDraftKey(scope: "different-server/account", sessionID: key.sessionID)
    let otherID = try store.add(file(), to: other)
    store.finishSubmission(batch, outcome: .accepted)
    XCTAssertEqual(store.draft(for: key).items.map(\.id), [addedLater])
    XCTAssertEqual(store.draft(for: other).items.map(\.id), [otherID])
    store.finishSubmission(batch, outcome: .accepted)
    XCTAssertEqual(store.draft(for: key).items.map(\.id), [addedLater])
  }

  func testUncertainSendRetainsFilesAndBlocksDuplicateUntilExplicitReview() async throws {
    let store = AttachmentDraftStore()
    let counter = UploadCounter()
    let id = try store.add(file(), to: key)
    await store.upload(id, in: key, using: counter.uploader)
    let batch = try store.beginSubmission(in: key)
    store.finishSubmission(batch, outcome: .uncertain)
    XCTAssertFalse(store.canSubmit(in: key))
    XCTAssertThrowsError(try store.beginSubmission(in: key))
    store.remove(id, from: key)
    XCTAssertTrue(store.draft(for: key).hasAttachments)
    store.acknowledgeUncertainty(in: AttachmentDraftKey(scope: "wrong", sessionID: key.sessionID))
    XCTAssertFalse(store.canSubmit(in: key))
    store.acknowledgeUncertainty(in: key)
    let retry = try store.beginSubmission(in: key)
    XCTAssertEqual(retry.attachments, batch.attachments)
    let uploads = await counter.count
    XCTAssertEqual(uploads, 1)
  }

  func testRejectedUploadRetainsFileAndExplicitRetryOnlyUploadsFailedItem() async throws {
    let store = AttachmentDraftStore()
    let counter = UploadCounter()
    let ready = try store.add(file(name: "ready.txt"), to: key)
    let failed = try store.add(file(name: "failed.txt"), to: key)
    await store.upload(ready, in: key, using: counter.uploader)
    await store.upload(failed, in: key) { _, _, _ in throw LocalServerClientError.httpStatus(413) }
    XCTAssertFalse(store.canSubmit(in: key))
    XCTAssertThrowsError(try store.beginSubmission(in: key))
    XCTAssertEqual(store.draft(for: key).items[1].file.filename, "failed.txt")
    await store.upload(failed, in: key, using: counter.uploader)
    XCTAssertTrue(store.canSubmit(in: key))
    let uploads = await counter.count
    XCTAssertEqual(uploads, 2)
  }

  func testUncertainUploadCannotBeRetriedOrBecomeTranscriptSubmission() async throws {
    let store = AttachmentDraftStore()
    let id = try store.add(file(), to: key)
    await store.upload(id, in: key) { _, _, _ in throw AttachmentUploadError.uploadUncertain }
    let counter = UploadCounter()
    await store.upload(id, in: key, using: counter.uploader)
    store.acknowledgeUncertainty(in: key)
    await store.upload(id, in: key, using: counter.uploader)
    let uploads = await counter.count
    XCTAssertEqual(uploads, 0)
    XCTAssertThrowsError(try store.beginSubmission(in: key))
    XCTAssertEqual(store.draft(for: key).items.first?.file.data, Data("retained bytes".utf8))
    guard case .uncertain = store.draft(for: key).items.first?.state else {
      return XCTFail("State lost")
    }
  }

  func testCancelInFlightPreservesBytesAndPreventsConcurrentDuplicateUpload() async throws {
    let store = AttachmentDraftStore()
    let id = try store.add(file(), to: key)
    let started = expectation(description: "Upload started")
    let progressSeen = expectation(description: "Progress delivered")
    let observation = store.$drafts.sink { drafts in
      if case .uploading(let progress) = drafts[self.key]?.items.first?.state, progress == 0.4 {
        progressSeen.fulfill()
      }
    }
    let upload = Task {
      await store.upload(id, in: key) { _, _, progress in
        started.fulfill()
        progress(0.4)
        do { try await Task.sleep(for: .seconds(30)) } catch {
          throw AttachmentUploadError.uploadUncertain
        }
        throw AttachmentUploadError.uploadUncertain
      }
    }
    await fulfillment(of: [started, progressSeen], timeout: 2)
    observation.cancel()
    let counter = UploadCounter()
    await store.upload(id, in: key, using: counter.uploader)
    store.remove(id, from: key)
    XCTAssertTrue(store.draft(for: key).hasAttachments)
    store.cancelUpload(id, in: key)
    await upload.value
    guard case .uncertain = store.draft(for: key).items.first?.state else {
      return XCTFail("Cancellation lost uncertainty")
    }
    XCTAssertEqual(store.draft(for: key).items.first?.file.data, Data("retained bytes".utf8))
    let count = await counter.count
    XCTAssertEqual(count, 0)
  }

  func testTransportAndStoreKeepExactRefsAfterRejectedSendAndBlockUncertainRetry() async throws {
    let harness = UploadFixtureHarness()
    let client = try harness.client()
    _ = try await client.connect()
    await client.prepareUploadIntegrationStream()
    let store = AttachmentDraftStore()
    let id = try store.add(file(), to: key)
    await store.upload(id, in: key, using: client)
    let first = try store.beginSubmission(in: key)
    harness.setMessage(.init(body: #"{"queued":false,"denied":true}"#, status: 202))
    let denied = try await client.submitMessage(
      "keep text", attachments: first.attachments, to: key.sessionID)
    XCTAssertTrue(denied.denied)
    store.finishSubmission(first, outcome: .rejected)
    let retry = try store.beginSubmission(in: key)
    XCTAssertEqual(retry.attachments, first.attachments)
    harness.setMessage(.init(error: .networkConnectionLost))
    do {
      _ = try await client.submitMessage(
        "keep text", attachments: retry.attachments, to: key.sessionID)
      XCTFail("Expected uncertain delivery")
    } catch { XCTAssertEqual(error as? LocalServerClientError, .deliveryUncertain) }
    store.finishSubmission(retry, outcome: .uncertain)
    XCTAssertThrowsError(try store.beginSubmission(in: key))
    XCTAssertEqual(
      harness.posts.filter { $0.url?.path.hasSuffix("/resources/files") == true }.count, 1)
    XCTAssertEqual(harness.posts.filter { $0.url?.path.hasSuffix("/events") == true }.count, 2)
    XCTAssertTrue(store.draft(for: key).hasAttachments)
  }

  private func file(name: String = "notes.txt") throws -> AttachmentUploadFile {
    try AttachmentUploadFile(filename: name, data: Data("retained bytes".utf8))
  }
}

extension LocalServerSessionClient {
  fileprivate func prepareUploadIntegrationStream() {
    watchedSessionID = "session_a"
    streamReady = true
  }
}

private actor UploadCounter {
  private(set) var count = 0
  nonisolated var uploader: AttachmentDraftStore.Uploader {
    { file, sessionID, progress in await self.upload(file, sessionID, progress) }
  }
  func upload(
    _ file: AttachmentUploadFile, _ sessionID: String, _ progress: @Sendable (Double) -> Void
  ) -> UploadedAttachment {
    count += 1
    return UploadedAttachment(
      serverURL: URL(string: "http://127.0.0.1:6767")!, sessionID: sessionID, id: "file_\(count)",
      filename: file.filename, isImage: false)
  }
}
