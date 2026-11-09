import CoreGraphics
import Foundation
import OmnigentCoreFFI
import Synchronization

@testable import OmnigentRemoteBrowser

/// A driver that records each call and fails input with `failure`, for what the fixture host
/// can't do: throw, or send a store data no host should.
nonisolated final class RecordingBrowserDriver: RemoteBrowserDriverProtocol {
  private let calls = Mutex<[String]>([])
  private let failure = Mutex<(any Error & Sendable)?>(nil)
  private let sentMice = Mutex<[MouseInput]>([])
  private let sentKeys = Mutex<[KeyInput]>([])
  private let sentIme = Mutex<[ImeInput]>([])

  var log: [String] { calls.withLock { $0 } }
  var mice: [MouseInput] { sentMice.withLock { $0 } }
  var keys: [KeyInput] { sentKeys.withLock { $0 } }
  var ime: [ImeInput] { sentIme.withLock { $0 } }

  func fail(with error: (any Error & Sendable)?) { failure.withLock { $0 = error } }

  private func record(_ call: String) { calls.withLock { $0.append(call) } }

  private func recordThrowing(_ call: String) throws {
    record(call)
    if let error = failure.withLock({ $0 }) { throw error }
  }

  func start() { record("start") }
  func stop() { record("stop") }
  func foreground() { record("foreground") }
  func setVisible(visible: Bool) { record("visible \(visible)") }
  func requestKeyframe(reason: KeyframeReason) { record("keyframe \(reason)") }
  func requestStill(kind: StillKind) { record("still \(kind)") }
  func takeControl() { record("take") }
  func releaseControl() { record("release") }
  func replyDialog(id: String, accept: Bool, text: String?) { record("dialog \(id)") }
  func updateSettings(update: RemoteBrowserSettingsUpdate) { record("settings") }
  func mouse(input: MouseInput) throws {
    sentMice.withLock { $0.append(input) }
    try recordThrowing("mouse")
  }
  func key(input: KeyInput) throws {
    sentKeys.withLock { $0.append(input) }
    try recordThrowing("key")
  }
  func ime(input: ImeInput) throws {
    sentIme.withLock { $0.append(input) }
    try recordThrowing("ime")
  }
  func touch(input: TouchInput) throws { try recordThrowing("touch") }
  func nav(op operation: NavOp, url: String?) throws {
    try recordThrowing("nav \(operation) \(url ?? "")")
  }
  func resize(viewport: RemoteViewport) throws { try recordThrowing("resize") }
  func setViewport(request: RemoteViewportRequest?) throws { try recordThrowing("viewport") }
  func edit(op operation: RemoteEditOp, text: String?) throws {
    try recordThrowing("edit \(operation) \(text ?? "")")
  }
}

/// Hands out one ``RecordingBrowserDriver`` and keeps the listener, so a test speaks as the host.
nonisolated final class RecordingConnector: RemoteBrowserConnecting {
  let driver = RecordingBrowserDriver()
  private let listeners = Mutex<[any RemoteBrowserListener]>([])

  var attachCount: Int { listeners.withLock { $0.count } }
  var listener: (any RemoteBrowserListener)? { listeners.withLock { $0.last } }

  func profiles(sessionID: String) throws -> [RemoteBrowserProfile] { [] }
  func createTab(sessionID: String, url: String?, profile: String?) throws
    -> RemoteBrowserTab
  { throw CancellationError() }
  func closeTab(sessionID: String, tabID: String) throws {}
  func attach(
    sessionID: String, tabID: String, mode: RemoteBrowserMode, hostID: String?,
    listener: any RemoteBrowserListener
  ) -> any RemoteBrowserDriverProtocol {
    listeners.withLock { $0.append(listener) }
    return driver
  }
}
