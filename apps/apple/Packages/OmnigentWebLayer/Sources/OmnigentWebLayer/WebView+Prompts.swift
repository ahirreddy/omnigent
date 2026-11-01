internal import CoreGraphics
public import Foundation
internal import OWLProtocol
internal import os

/// A drag the page started, for `WebSurfaceView` to run natively.
struct WebDragStart {
  let data: WebDragData
  let operations: WebDragOperations
  /// Where the drag started, in view points.
  let location: CGPoint
  /// The drag image as PNG, when the page provided one.
  let image: Data?
}

/// Protocol 1.1 host requests: prompts, popups, policies, IME state and drags. See DESIGN.md,
/// "Browser UI over the channel".
extension WebView {
  func handleBrowserUI(_ kind: OWLMessageKind, _ fields: WireDecoder) -> Bool {
    if handlePromptRequest(kind, fields) {
      return true
    }
    switch kind {
    case .promptCancelled:
      withdrawPrompt(
        id: fields.u64(.promptID) ?? 0, reason: fields.string(.reason) ?? "Withdrawn by the host.")
    case .downloadUpdated:
      session.downloads.update(fields)
    case .popupBlocked:
      popupBlocked(fields)
    case .navigationBlocked:
      let url = fields.string(.URL).flatMap(URL.init(string:))
      let reason = fields.string(.reason) ?? "Blocked by the navigation rules."
      lastError = .navigationBlocked(url: url, reason: reason)
      onEvent?(.navigationBlocked(url: url, reason: reason))
    case .imeCompositionChanged:
      compositionCharacterRects = Self.rects(fields.string(.rects) ?? "[]")
    case .textSelectionChanged:
      selectedText = fields.string(.text) ?? ""
      let start = Int(fields.i64(.rangeStart) ?? 0)
      selectedRange = NSRange(
        location: start, length: max(0, Int(fields.i64(.rangeEnd) ?? 0) - start))
    case .startDrag:
      startDrag(fields)
    case .dragCursor:
      dragOperation = WebDragOperations(rawValue: fields.u64(.dragOperations) ?? 0)
    default:
      return false
    }
    return true
  }

  private func handlePromptRequest(_ kind: OWLMessageKind, _ fields: WireDecoder) -> Bool {
    let id = fields.u64(.promptID) ?? 0
    do throws(WebLayerError) {
      switch kind {
      case .jsDialog: present(.dialog(WebDialogRequest(id: id, webView: self, fields: fields)))
      case .permissionRequest:
        present(.permission(WebPermissionRequest(id: id, webView: self, fields: fields)))
      case .fileChooser:
        present(.fileChooser(try WebFileChooserRequest(id: id, webView: self, fields: fields)))
      case .downloadRequest:
        present(.download(WebDownloadRequest(id: id, webView: self, fields: fields)))
      case .authRequest:
        present(.authentication(WebAuthRequest(id: id, webView: self, fields: fields)))
      case .certificateError:
        present(
          .certificateError(WebCertificateErrorRequest(id: id, webView: self, fields: fields)))
      case .contextMenu:
        present(.contextMenu(try WebContextMenu(id: id, webView: self, fields: fields)))
      case .colorChooser: present(.color(WebColorRequest(id: id, webView: self, fields: fields)))
      default: return false
      }
    } catch {
      Logger.view.error(
        "View \(self.id) got a malformed prompt \(kind.rawValue): \(error.localizedDescription, privacy: .public)"
      )
      lastError = error
    }
    return true
  }

  private func present(_ prompt: WebPrompt) {
    pendingPrompts.append(prompt)
    guard let uiDelegate else {
      denyWithoutDelegate(prompt)
      return
    }
    uiDelegate.webView(self, didRequest: prompt)
  }

  /// Protocol 1.0 behavior for apps without UI: deny, and report it.
  private func denyWithoutDelegate(_ prompt: WebPrompt) {
    let feature: String
    switch prompt {
    case .dialog(let request):
      feature = "JavaScript dialog"
      request.cancel()
    case .permission(let request):
      feature = "Permission prompt"
      request.deny()
    case .fileChooser(let request):
      feature = "File chooser"
      request.cancel()
    case .download(let request):
      feature = "Download"
      request.cancel()
    case .authentication(let request):
      feature = "HTTP authentication"
      request.cancel()
    case .certificateError(let request):
      feature = "Certificate error"
      request.cancel()
    case .contextMenu(let request):
      feature = "Context menu"
      request.dismiss()
    case .color(let request):
      feature = "Color chooser"
      request.cancel()
    }
    let detail = "No WebViewUIDelegate is set for view \(id)."
    lastError = .featureBlocked(feature: feature, detail: detail)
    onEvent?(.featureBlocked(feature: feature, detail: detail))
  }

  func promptFinished(_ request: WebPromptRequest) {
    pendingPrompts.removeAll { $0.request === request }
    changed()
  }

  private func withdrawPrompt(id: UInt64, reason: String) {
    guard let prompt = pendingPrompts.first(where: { $0.id == id }) else {
      return  // Answered already; the host's cancel crossed our reply.
    }
    prompt.request.withdraw(reason: reason)
    pendingPrompts.removeAll { $0.id == id }
    uiDelegate?.webView(self, didCancel: prompt, reason: reason)
  }

  func withdrawPrompts(reason: String) {
    for prompt in pendingPrompts {
      withdrawPrompt(id: prompt.id, reason: reason)
    }
  }

  /// Sends the popup policy and navigation rules to a 1.1 host.
  func sendPolicies() {
    guard status == .live, session.supportsBrowserUI else { return }
    send(.setPopupPolicy, WireEncoder().u64(.popupPolicy, popupPolicy.wire.rawValue))
    var rules = WireEncoder()
    if let navigationRules { rules = rules.string(.rules, navigationRules.json) }
    send(.setNavigationRules, rules)
  }

  /// A host-created popup arrived for this opener.
  func didOpen(_ popup: WebPopup) {
    guard let uiDelegate else {
      let detail =
        "No WebViewUIDelegate adopted the popup for \(popup.targetURL?.absoluteString ?? "a page")."
      popup.webView.close()
      lastError = .featureBlocked(feature: "Popup", detail: detail)
      onEvent?(.featureBlocked(feature: "Popup", detail: detail))
      return
    }
    uiDelegate.webView(self, didOpen: popup)
  }

  private func popupBlocked(_ fields: WireDecoder) {
    let blocked = WebBlockedPopup(
      url: fields.string(.URL).flatMap(URL.init(string:)),
      disposition: WebPopupDisposition(wire: fields.u64(.disposition) ?? 0),
      userGesture: fields.bool(.userGesture),
      reason: fields.string(.reason) ?? "Blocked by the popup policy.")
    onEvent?(.popupBlocked(blocked))
    if let uiDelegate {
      uiDelegate.webView(self, didBlock: blocked)
    } else {
      lastError = .popupBlocked(url: blocked.url, reason: blocked.reason)
    }
  }

  private func startDrag(_ fields: WireDecoder) {
    let data: WebDragData
    do throws(WebLayerError) {
      data = try WireJSON.decode(
        WebDragData.self, fields.string(.dragData) ?? "{}", field: "DragData")
    } catch {
      lastError = error
      renderer.dragSourceEnded(at: .zero, operation: [])
      return
    }
    let start = WebDragStart(
      data: data, operations: WebDragOperations(rawValue: fields.u64(.dragOperations) ?? 0),
      location: CGPoint(x: fields.double(.X) ?? 0, y: fields.double(.Y) ?? 0),
      image: fields.data(.image))
    onEvent?(.dragStarted(data))
    guard let onStartDrag else {
      // No view on screen to drag from (an agent view): end it at once.
      renderer.dragSourceEnded(at: start.location, operation: [])
      return
    }
    onStartDrag(start)
  }

  private static func rects(_ json: String) -> [CGRect] {
    let values: [[Double]]
    do {
      values = try JSONDecoder().decode([[Double]].self, from: Data(json.utf8))
    } catch {
      Logger.view.error(
        "ImeCompositionChanged carried malformed Rects \(json, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return []
    }
    return values.compactMap { value in
      value.count == 4 ? CGRect(x: value[0], y: value[1], width: value[2], height: value[3]) : nil
    }
  }
}
