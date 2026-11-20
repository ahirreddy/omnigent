public import CoreGraphics
internal import Foundation

/// Sending: each tool freezes its drafts, takes its screenshot, and hands the request to the
/// app, which sends it to the tab's session; then the tool closes.
extension BrowserDesignTools {
  /// Hands Annotate's request to the app with a screenshot of the element, where it can still
  /// be found where it was picked; without one (saying why) when it can't.
  public func sendAnnotation() async {
    guard annotationBlocked == nil, let picked, let send, beginSend(.annotate) else { return }
    let opening = self.opening
    let request = self.request
    let screenshot = await elementScreenshot(picked)
    guard opening == self.opening else { return }
    let message = BrowserDesignRequest(
      content: .element(picked.hit.element, request: request), pageURL: pageURL(),
      screenshotPNG: try? screenshot.get())
    do throws(BrowserError) {
      try send(message)
    } catch {
      sendFailed(error, opening: opening)
      return
    }
    close()
    switch screenshot {
    case .success:
      show(Self.sendingNotice, isError: false)
    case .failure(let error):
      show("\(Self.withoutScreenshotNotice) \(error.localizedDescription)", isError: false)
    }
  }

  /// The picked element's screenshot, or why there is none: it's gone from where it was
  /// picked, or the page can't be captured.
  private func elementScreenshot(_ picked: BrowserDesignPick) async -> Result<Data, BrowserError> {
    guard let page else { return .failure(.tabNotReady) }
    do throws(BrowserError) {
      guard let now = try await page.hitTest(picked.point), now.isSameElement(as: picked.hit)
      else { return .failure(.snapshotFailed("The element moved or changed.")) }
      let snapshot = try await page.snapshot()
      return .success(try BrowserDesignCapture.elementPNG(snapshot: snapshot, hit: now))
    } catch {
      return .failure(error)
    }
  }

  /// Hands Draw's request to the app: the page's snapshot with the marks drawn on, for an
  /// overlay of `viewSize` points.
  public func sendDrawing(viewSize: CGSize) async {
    guard drawingBlocked == nil, let page, let send, beginSend(.draw) else { return }
    let opening = self.opening
    let marks = self.marks
    let note = self.note
    do throws(BrowserError) {
      let snapshot = try await page.snapshot()
      guard opening == self.opening else { return }
      let png = try BrowserDesignCapture.drawingPNG(
        snapshot: snapshot, marks: marks, viewSize: viewSize)
      try send(
        BrowserDesignRequest(
          content: .drawing(note: note, marks: marks.count), pageURL: pageURL(),
          screenshotPNG: png))
    } catch {
      sendFailed(error, opening: opening)
      return
    }
    close()
    show(Self.sendingNotice, isError: false)
  }
}
