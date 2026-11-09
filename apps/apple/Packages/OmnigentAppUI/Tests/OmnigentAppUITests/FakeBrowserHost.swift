import Foundation
import SwiftUI

@testable import OmnigentAppUI

/// A browser that keeps its pages in memory, so tab behavior can be tested without web views.
@MainActor
final class FakeBrowserHost: BrowserTabHosting {
  /// Thrown when a page's state can't be encoded.
  struct EncodingFailed: Error {}

  var madeURLs: [URL?] = []
  var statuses: [UUID: BrowserTabStatus] = [:]
  var closed: [UUID] = []
  var attached: [UUID] = []
  var detached: [UUID] = []
  var shownElsewhere: Set<UUID> = []
  var snapshotState: Data?
  var snapshotFails = false
  var closeFails = false
  var closeState: Data?

  func makePage(url: URL?) -> (id: UUID, state: Data?) {
    madeURLs.append(url)
    let id = UUID()
    statuses[id] = BrowserTabStatus(title: url?.host() ?? "", url: url)
    return (id, Data("state".utf8))
  }

  func content(
    for id: UUID, restoring state: Data?, navigation: BrowserTabNavigation?,
    onChange: @escaping @MainActor () -> Void
  ) -> AnyView {
    AnyView(Text("Page \(statuses[id]?.title ?? "")"))
  }

  func status(of id: UUID) -> BrowserTabStatus? { statuses[id] }

  func snapshot(of id: UUID) throws -> Data? {
    if snapshotFails { throw EncodingFailed() }
    return snapshotState
  }

  func close(_ id: UUID) throws -> Data? {
    closed.append(id)
    if closeFails { throw EncodingFailed() }
    return closeState
  }

  func agentContent(for sessionID: String) -> AnyView? {
    sessionID == "conv_agent" ? AnyView(Text("Agent page")) : nil
  }

  func attach(window: UUID, tabs: SessionTabGroups) { attached.append(window) }
  func isPageShown(_ id: UUID, outside window: UUID) -> Bool { shownElsewhere.contains(id) }
  func detach(window: UUID) { detached.append(window) }
}
