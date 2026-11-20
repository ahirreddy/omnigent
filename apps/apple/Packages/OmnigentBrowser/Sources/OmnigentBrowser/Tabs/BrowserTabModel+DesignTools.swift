internal import CoreGraphics
internal import Foundation

/// Annotate and Draw on the tab's page: the tools reach the live engine tab through the model,
/// and hand their requests to the environment's sender with the model.
extension BrowserTabModel {
  /// Whether the toolbar offers Annotate and Draw: the app takes their requests, and a page
  /// (not a new tab's empty one) is showing.
  public var offersDesignTools: Bool {
    environment.designRequestSender != nil && tab != nil && !showsEmptyPage
  }

  /// Whether the page's scripts can't see the element picker (it runs in an isolated world).
  public var designToolsAreIsolated: Bool { tab?.evaluatesInIsolatedWorld ?? false }

  func installDesignTools() {
    designTools.pageURL = { [weak self] in self?.url }
    designTools.page = BrowserDesignPageAccess(
      hitTest: { [weak self] point async throws(BrowserError) -> BrowserDesignHit? in
        guard let tab = self?.tab else { throw .tabNotReady }
        guard let script = BrowserDesignPicker.script(at: point) else { return nil }
        return try BrowserDesignPicker.hit(from: try await tab.evaluateIsolatedJavaScript(script))
      },
      snapshot: { [weak self] () async throws(BrowserError) -> CGImage in
        guard let tab = self?.tab else { throw .tabNotReady }
        return try BrowserDesignCapture.image(fromPNG: try await tab.takeSnapshotPNG())
      },
      viewport: { [weak self] () async throws(BrowserError) -> BrowserDesignViewport in
        guard let tab = self?.tab else { throw .tabNotReady }
        return try BrowserDesignViewport.viewport(
          from: try await tab.evaluateIsolatedJavaScript(BrowserDesignViewport.script))
      })
    designTools.send = { [weak self] request throws(BrowserError) in
      guard let self, let sender = self.environment.designRequestSender else {
        throw .designToolFailed("This window can't send design requests to a session.")
      }
      try sender(request, self)
    }
  }
}
