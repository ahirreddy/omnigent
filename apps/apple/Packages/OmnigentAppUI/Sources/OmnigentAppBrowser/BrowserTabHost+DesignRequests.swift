import Foundation
import OmnigentAppUI
import OmnigentBrowser
import OmnigentStores
import OmnigentUIComponents

/// Annotate and Draw: a page's request goes to its window's outbox, for the session whose tabs
/// hold the page, worded as the web's messages; the page hears how it went.
extension BrowserTabHost {
  /// Queues `request` from `model`'s page for the session the page's tab belongs to.
  /// - Throws: `BrowserError.designToolFailed` when the page is in no session's tabs.
  func queueDesignRequest(_ request: BrowserDesignRequest, from model: BrowserTabModel)
    throws(BrowserError)
  {
    guard let pageID = pageID(of: model), let place = session(holding: pageID),
      let outbox = designOutboxes[place.window]
    else {
      throw .designToolFailed(
        "This page isn't in a session's tabs, so there's no agent to send it to.")
    }
    let tools = model.designTools
    let message = DesignOutboxRequest.Message(
      tool: request.tool == .annotate ? .annotate : .draw, label: request.label,
      text: DesignRequestMessage.text(request), files: DesignRequestMessage.files(request))
    outbox.queue(message, to: place.sessionID) { [weak tools] outcome in
      switch outcome {
      case .sent: tools?.show(DesignRequestOutbox.Copy.sent, isError: false)
      case .failed(let message): tools?.show(message, isError: true)
      }
    }
  }

  /// The window and session whose tabs hold `pageID`.
  func session(holding pageID: UUID) -> (window: UUID, sessionID: String)? {
    for (window, tabs) in windows {
      for (sessionID, group) in tabs.groups
      where group.tabs.contains(where: { $0.content == .browser(browserID: pageID) }) {
        return (window, sessionID)
      }
    }
    return nil
  }
}

/// A design tool request as the session receives it: the web's words and the screenshot.
enum DesignRequestMessage {
  /// The message, as the web's `buildDesignModePrompt` or `buildDrawPrompt` words it.
  static func text(_ request: BrowserDesignRequest) -> String {
    switch request.content {
    case .element(let element, let words):
      DesignToolPrompt.annotate(
        element: DesignPromptElement(
          tag: element.tag, id: element.id, classes: element.classes, text: element.text,
          testID: element.testID, ariaLabel: element.ariaLabel, role: element.role),
        request: words, screenshotAttached: request.screenshotPNG != nil)
    case .drawing(let note, _):
      DesignToolPrompt.draw(note: note, url: request.pageURL)
    }
  }

  /// The screenshot, named as the web names it.
  static func files(_ request: BrowserDesignRequest) -> [DesignOutboxRequest.File] {
    guard let png = request.screenshotPNG else { return [] }
    let name = request.tool == .annotate ? "design-element.png" : "design-drawing.png"
    return [DesignOutboxRequest.File(name: name, mediaType: "image/png", data: png)]
  }
}
