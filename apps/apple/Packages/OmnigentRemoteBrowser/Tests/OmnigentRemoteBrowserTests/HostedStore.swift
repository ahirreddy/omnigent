import CoreGraphics
import Foundation
import OmnigentCoreFFI

@testable import OmnigentRemoteBrowser

#if os(macOS)
  import AppKit
  import OmnigentViewTesting
#else
  import UIKit
#endif

/// A store attached to a recording driver, so a test speaks as the host. The pasteboard is kept
/// off the system's, and a saved viewport mode doesn't outlive the test.
@MainActor
struct HostedStore {
  let connector = RecordingConnector()
  let store: RemoteBrowserStore

  init(lastURL: String = "", mode: RemoteViewportMode = .keep) {
    #if os(macOS)
      SystemSideEffects.install()
    #endif
    UserDefaults.standard.removeObject(forKey: RemoteViewportModeDefaults.key)
    store = RemoteBrowserStore(sessionID: "s", tabID: "t", lastURL: lastURL)
    store.pasteboard = MemoryPasteboard()
    store.attach(using: connector, mode: .control, hostID: nil)
    store.viewportMode = mode
  }

  var driverCalls: [String] { connector.driver.log }

  /// Forgets the saved mode; call when the test ends.
  func finish() {
    store.detach()
    UserDefaults.standard.removeObject(forKey: RemoteViewportModeDefaults.key)
  }

  /// A snapshot in control of the page, unless the arguments say otherwise.
  static func snapshot(
    connection: RemoteBrowserConnection = .attached(mode: .control),
    owner: ControlOwner = .user, holder: ControlHolder = .this,
    viewport: RemoteViewport? = RemoteViewport(width: 1000, height: 500, dpr: 1),
    edit: Bool = true
  ) -> RemoteBrowserSnapshot {
    var snapshot = RemoteBrowserSnapshot.initial(url: "https://example.com/", profile: "work")
    snapshot.connection = connection
    snapshot.control = RemoteBrowserControl(
      owner: owner, holder: holder, userId: nil, handoff: nil)
    snapshot.viewport = viewport
    snapshot.capabilities.edit = edit
    return snapshot
  }

  /// Delivers a snapshot and lets the store and any view observing it take it in.
  func hostSends(_ snapshot: RemoteBrowserSnapshot) async {
    connector.listener?.onState(snapshot: snapshot)
    await letTasksRun()
  }
}

/// A store in control with a view in no window; 1000 x 1000 points showing a page 1000 x 500,
/// so the page is y 250 to 750 and the rest is letterbox.
@MainActor
func inControl(
  _ snapshot: RemoteBrowserSnapshot = HostedStore.snapshot()
) async -> (HostedStore, RemoteBrowserView) {
  let hosted = HostedStore()
  let view = RemoteBrowserView(store: hosted.store)
  view.frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
  await hosted.hostSends(snapshot)
  return (hosted, view)
}

/// Lets queued main-actor work run; `Task.sleep` is slow at background priority.
@MainActor
func letTasksRun() async {
  for _ in 0..<40 { await Task.yield() }
}
