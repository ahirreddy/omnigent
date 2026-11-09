import CoreMedia
import Foundation
import OmnigentCoreFFI
import OmnigentViewTesting
import SwiftUI
import Synchronization
import Testing

@testable import OmnigentRemoteBrowser

/// What a fixture driver told its listener.
nonisolated private final class FixtureEvents: RemoteBrowserListener {
  private let states = Mutex<[RemoteBrowserSnapshot]>([])
  private let notices = Mutex<[RemoteBrowserNotice]>([])

  var lastState: RemoteBrowserSnapshot? { states.withLock { $0.last } }
  var noticeMessages: [String] { notices.withLock { $0.map(\.message) } }

  func onState(snapshot: RemoteBrowserSnapshot) { states.withLock { $0.append(snapshot) } }
  func onVideo(frame: VideoFrame) {}
  func onStill(still: StillImage) {}
  func onClosed(reason: RemoteTabClosedReason?) {}
  func onNotice(notice: RemoteBrowserNotice) { notices.withLock { $0.append(notice) } }
  func onClipboard(op operation: RemoteEditOp, text: String) {}
}

/// A folder read as a resource bundle, so a fixture's files can be absent or unreadable.
private struct FixtureFolder {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "fixture-resources-\(UUID().uuidString)", directoryHint: .isDirectory)

  init() throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  var bundle: Bundle {
    get throws { try #require(Bundle(url: url)) }
  }

  /// `Bundle` caches a folder's listing per path, so later files need a folder of their own.
  static func readAgain(_ folder: Self) throws -> Bundle {
    let copy = try Self()
    try FileManager.default.removeItem(at: copy.url)
    try FileManager.default.copyItem(at: folder.url, to: copy.url)
    return try copy.bundle
  }

  /// Copies a recorded stream and its index in.
  func addStream(_ name: String) throws {
    let recorded = SharedFixtures.directory.appending(path: "h264")
    for file in ["\(name).annexb", "\(name).frames.json"] {
      try FileManager.default.copyItem(
        at: recorded.appending(path: file), to: url.appending(path: file))
    }
  }

  /// A folder under a file's name: found by name, and unreadable as a file.
  func addUnreadable(_ file: String) throws {
    try FileManager.default.createDirectory(
      at: url.appending(path: file), withIntermediateDirectories: true)
  }

  func remove() {
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      Issue.record("cleanup failed: \(error)")
    }
  }
}

@MainActor
@Suite("Fixture host without its files", .serialized)
struct FixtureResourceFailureTests {
  private func eventually(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<400 {
      if condition() { return true }
      try await Task.sleep(for: .milliseconds(5))
    }
    return condition()
  }

  /// A driver over `folder` for a tab that exists.
  private func driver(_ resources: Bundle, events: FixtureEvents)
    -> any RemoteBrowserDriverProtocol
  {
    let host = FixtureRemoteBrowser(profiles: [], latency: .milliseconds(1), resources: resources)
    host.addTab(id: "t", url: "https://example.com/")
    return host.attach(sessionID: "s", tabID: "t", mode: .control, hostID: nil, listener: events)
  }

  @Test("a stream that isn't there fails the connection and says which")
  func noStream() async throws {
    let folder = try FixtureFolder()
    defer { folder.remove() }
    let events = FixtureEvents()
    let driver = driver(try folder.bundle, events: events)
    defer { driver.stop() }
    driver.start()
    #expect(
      try await eventually {
        if case .failed = events.lastState?.connection { true } else { false }
      })
    guard case .failed(_, let message, let requiresSignIn)? = events.lastState?.connection else {
      return
    }
    #expect(message.contains(FixtureVideoStream.large))
    #expect(!requiresSignIn)
  }

  @Test("a thumbnail that's absent or unreadable becomes a notice, not a still")
  func noThumbnail() throws {
    let folder = try FixtureFolder()
    defer { folder.remove() }
    let absent = FixtureEvents()
    driver(try folder.bundle, events: absent).requestStill(kind: .thumbnail)
    #expect(absent.noticeMessages.first?.contains("thumbnail_320x200.jpg") == true)

    try folder.addUnreadable("thumbnail_320x200.jpg")
    let unreadable = FixtureEvents()
    driver(try FixtureFolder.readAgain(folder), events: unreadable).requestStill(kind: .thumbnail)
    #expect(unreadable.noticeMessages.count == 1)
    #expect(unreadable.noticeMessages != absent.noticeMessages)
  }

  @Test("navigating to the small stream without its files keeps playing and says so")
  func noSmallStream() async throws {
    let folder = try FixtureFolder()
    defer { folder.remove() }
    try folder.addStream(FixtureVideoStream.large)
    let events = FixtureEvents()
    let driver = driver(try folder.bundle, events: events)
    defer { driver.stop() }
    driver.start()
    #expect(
      try await eventually {
        if case .attached = events.lastState?.connection { true } else { false }
      })
    // Decoding the first frame sets the stream the switch compares against.
    try driver.nav(op: .navigate, url: "https://small.example/")
    #expect(try await eventually { !events.noticeMessages.isEmpty })
    #expect(events.noticeMessages.first?.contains(FixtureVideoStream.small) == true)
    guard case .attached = events.lastState?.connection else {
      Issue.record("expected to stay attached")
      return
    }
  }

  @Test("a stream that can't be read is malformed, unlike one that's missing")
  func unreadableStream() throws {
    let folder = try FixtureFolder()
    defer { folder.remove() }
    let name = FixtureVideoStream.large
    #expect(throws: FixtureStreamError.missingResource(name)) {
      try FixtureVideoStream(named: name, in: try folder.bundle)
    }
    try folder.addUnreadable("\(name).annexb")
    try folder.addUnreadable("\(name).frames.json")
    #expect {
      try FixtureVideoStream(named: name, in: try FixtureFolder.readAgain(folder))
    } throws: { error in
      if case .malformed = error as? FixtureStreamError { true } else { false }
    }
  }

  @Test("the fixture tab adds its tab to the shared host and shows the page's chrome")
  func fixtureTab() async throws {
    let id = "btab_\(UUID().uuidString)"
    let screen = OffscreenWindow(
      RemoteBrowserFixtureTab(id: id, url: "https://fixture.example/"), width: 800, height: 500)
    defer { screen.close() }
    screen.settle(0.3)
    #expect(!screen.controlFrames.isEmpty)
    try await FixtureRemoteBrowser.shared.closeTab(sessionID: "fixture", tabID: id)
  }
}

private struct DecoderDied: Error, CustomStringConvertible {
  var description: String { "the decoder died" }
}

@MainActor
@Suite("Decoder recovery")
struct DecoderRecoveryTests {
  private func renderer() throws -> (RemoteVideoRenderer, FixtureVideoStream) {
    let stream = try SharedFixtures.stream(FixtureVideoStream.large)
    let renderer = RemoteVideoRenderer()
    renderer.enqueue(stream.frames[0])
    #expect(renderer.framesEnqueued == 1)
    return (renderer, stream)
  }

  @Test("a failed decoder reports why, asks for one keyframe, and drops deltas until it comes")
  func failedDecoder() throws {
    let (renderer, stream) = try renderer()
    var requests: [KeyframeReason] = []
    renderer.requestKeyframe = { requests.append($0) }
    renderer.recover(failed: true, error: DecoderDied(), needsFlush: true)
    #expect(renderer.lastError == "the decoder died")
    #expect(requests == [.decoderError])
    renderer.recover(failed: true, error: nil, needsFlush: false)
    #expect(renderer.lastError == "unknown decoder error")
    #expect(requests == [.decoderError])
    renderer.enqueue(stream.frames[1])
    #expect(renderer.framesEnqueued == 1)
    renderer.enqueue(stream.frames[0])
    #expect(renderer.framesEnqueued == 2)
    #expect(renderer.lastError == nil)
  }

  @Test("a flush the system requires asks for a keyframe, without calling it an error")
  func requiredFlush() throws {
    let (renderer, _) = try renderer()
    var requests: [KeyframeReason] = []
    renderer.requestKeyframe = { requests.append($0) }
    renderer.recover(failed: false, error: nil, needsFlush: false)
    #expect(requests.isEmpty)
    renderer.recover(failed: false, error: nil, needsFlush: true)
    #expect(requests == [.flush])
    #expect(renderer.lastError == nil)
  }
}

@Suite("Hardware decode report")
struct HardwareDecodeProbeTests {
  @Test("a format no decoder takes reports that no session was made")
  func noDecoder() throws {
    var format: CMVideoFormatDescription?
    let made = unsafe CMVideoFormatDescriptionCreate(
      allocator: nil, codecType: 0x7878_7878, width: 16, height: 16, extensions: nil,
      formatDescriptionOut: &format)
    #expect(made == noErr)
    let report = HardwareDecodeReport.probe(try #require(format))
    #expect(!report.sessionCreated)
    #expect(!report.usingHardware)
    #expect(report.status != noErr)
    #expect(report.description.contains("\(report.status)"))
  }
}
