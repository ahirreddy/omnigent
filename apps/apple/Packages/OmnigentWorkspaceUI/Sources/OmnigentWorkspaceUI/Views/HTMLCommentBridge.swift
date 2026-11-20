import Foundation
import WebKit
import os

/// Text selected in an HTML preview: what the reader sees, and which copy of it (0-based, in
/// document order) they picked.
nonisolated struct HTMLSelection: Hashable, Sendable {
  let text: String
  let occurrence: Int
}

/// A comment the HTML preview highlights: its anchor text and which copy of it it is on.
nonisolated struct HTMLCommentMark: Hashable, Sendable {
  let id: String
  let anchor: String
  let occurrence: Int?

  /// What the page script reads.
  var payload: [String: Any] {
    var payload: [String: Any] = ["id": id, "anchor_content": anchor]
    if let occurrence { payload["occ"] = occurrence }
    return payload
  }
}

/// A zoom shortcut pressed in the preview.
nonisolated enum HTMLZoomKey: String, Sendable {
  case zoomIn = "in"
  case zoomOut = "out"
  case reset
}

/// What the preview's comment script tells the app, as the web's bridge protocol.
nonisolated enum HTMLBridgeMessage: Equatable, Sendable {
  /// The script is in place and takes the comments.
  case ready
  /// The reader selected text.
  case selection(HTMLSelection)
  /// The reader clicked a comment's highlighted text.
  case commentClick(String)
  /// A click landed on no selection and no comment.
  case selectionCleared
  /// A zoom shortcut.
  case zoom(HTMLZoomKey)

  /// The message in a script message body; `nil` for a malformed one.
  static func parse(_ body: Any) -> Self? {
    guard let object = body as? [String: Any], let type = object["type"] as? String else {
      return nil
    }
    switch type {
    case "ready":
      return .ready
    case "selection":
      guard let text = object["text"] as? String,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return nil }
      let occurrence = object["occ"] as? Int ?? 0
      return .selection(HTMLSelection(text: text, occurrence: max(0, occurrence)))
    case "commentClick":
      guard let id = object["id"] as? String, !id.isEmpty else { return nil }
      return .commentClick(id)
    case "selectionCleared":
      return .selectionCleared
    case "zoom":
      return (object["action"] as? String).flatMap(HTMLZoomKey.init).map(Self.zoom)
    default:
      return nil
    }
  }
}

/// Runs the comment script in the preview and relays its messages. The script lives in its own
/// content world, so the page's scripts can't reach it; WebKit holds this handler strongly, so
/// it holds its receiver weakly.
final class HTMLCommentBridge: NSObject, WKScriptMessageHandler {
  static let world = WKContentWorld.world(name: "omnigent-html-comments")
  static let handlerName = "omniComments"
  private static let logger = Logger(
    subsystem: "com.omnigent.workspace", category: "HTMLCommentBridge")

  /// Told each message.
  var received: (HTMLBridgeMessage) -> Void = { _ in }

  /// Adds the script and this handler to `controller`.
  func install(in controller: WKUserContentController) {
    guard let source = Self.source else { return }
    controller.addUserScript(
      WKUserScript(
        source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
    controller.add(self, contentWorld: Self.world, name: Self.handlerName)
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard let parsed = HTMLBridgeMessage.parse(message.body) else {
      Self.logger.error("Ignored a malformed HTML comment bridge message.")
      return
    }
    received(parsed)
  }

  /// Sends the comments and the selected one to the page script.
  static func push(_ marks: [HTMLCommentMark], active: HTMLCommentMark?, to webView: WKWebView) {
    let script = "omniComments.setComments(comments); omniComments.setActive(active);"
    let active: Any =
      active.map { mark -> [String: Any] in
        var payload = mark.payload
        payload["comment_id"] = mark.id
        return payload
      } ?? NSNull()
    webView.callAsyncJavaScript(
      script, arguments: ["comments": marks.map(\.payload), "active": active], in: nil,
      in: world
    ) { result in
      if case .failure(let error) = result {
        logger.error("Could not show the HTML comments: \(error.localizedDescription)")
      }
    }
  }

  /// The script, from the package's resources; `nil` (logged) when it is missing.
  private static let source: String? = {
    guard let url = Bundle.module.url(forResource: "HTMLCommentBridge", withExtension: "js") else {
      logger.fault("The HTML comment bridge script is missing from the bundle.")
      return nil
    }
    do {
      return try String(contentsOf: url, encoding: .utf8)
    } catch {
      logger.fault("Could not read the HTML comment bridge: \(error.localizedDescription)")
      return nil
    }
  }()
}
