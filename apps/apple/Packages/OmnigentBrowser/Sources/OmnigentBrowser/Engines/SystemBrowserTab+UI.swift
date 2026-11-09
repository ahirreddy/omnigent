internal import Foundation
internal import WebKit

/// Page UI requests on WebKit: JavaScript dialogs, the open panel, camera and microphone, and
/// popups, mapped to the engine-neutral prompts.
extension SystemBrowserTab: WKUIDelegate {
  /// Queues `prompt` for the delegate, or denies it when there is none.
  func present(_ prompt: BrowserPrompt) {
    state.enqueue(prompt)
    guard let delegate else {
      Self.deny(prompt)
      state.lastError = .featureUnsupported(
        feature: "\(prompt.kindName) (no tab delegate)", engine: .system)
      return
    }
    delegate.tab(self, didRequest: prompt)
  }

  /// Drops answered prompts from the queue. Prompts are marked finished before their answer
  /// runs, so this is called from the answer.
  func pruneFinishedPrompts() {
    for prompt in state.pendingPrompts where prompt.base.isFinished {
      state.remove(prompt.base)
    }
  }

  func withdrawPrompts(reason: String) {
    for prompt in state.pendingPrompts {
      // WebKit raises an exception if a completion handler goes unanswered.
      Self.deny(prompt)
      prompt.base.withdraw(reason: reason)
      state.remove(prompt.base)
      delegate?.tab(self, didCancel: prompt)
    }
  }

  static func deny(_ prompt: BrowserPrompt) {
    switch prompt {
    case .dialog(let dialog): dialog.cancel()
    case .permission(let permission): permission.deny()
    case .fileChooser(let chooser): chooser.cancel()
    case .download(let download): download.cancel()
    case .authentication(let auth): auth.cancel()
    case .certificateError(let certificate): certificate.cancel()
    case .color(let color): color.cancel()
    }
  }

  private func dialog(
    _ kind: BrowserDialogKind, frame: WKFrameInfo, message: String, defaultText: String,
    answer: @escaping (Bool, String?) -> Void
  ) {
    let prompt = BrowserDialogPrompt(
      kind: kind, origin: Self.originURL(frame.securityOrigin), message: message,
      defaultText: defaultText
    ) { [weak self] accepted, text in
      answer(accepted, text)
      self?.pruneFinishedPrompts()
    }
    present(.dialog(prompt))
  }

  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    dialog(.alert, frame: frame, message: message, defaultText: "") { _, _ in completionHandler() }
  }

  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    dialog(.confirm, frame: frame, message: message, defaultText: "") { accepted, _ in
      completionHandler(accepted)
    }
  }

  func webView(
    _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
    defaultText: String?, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable (String?) -> Void
  ) {
    let initial = defaultText ?? ""
    let answer: (Bool, String?) -> Void = { accepted, text in
      completionHandler(accepted ? (text ?? initial) : nil)
    }
    dialog(.prompt, frame: frame, message: prompt, defaultText: initial, answer: answer)
  }

  #if os(macOS)
    func webView(
      _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
      initiatedByFrame frame: WKFrameInfo,
      // swiftlint:disable:next discouraged_optional_collection
      completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void  // WebKit's signature.
    ) {
      let mode: BrowserFileChooserMode =
        parameters.allowsDirectories
        ? .openFolder : parameters.allowsMultipleSelection ? .openMultiple : .open
      let prompt = BrowserFileChooserPrompt(
        mode: mode, allowedExtensions: [], allowedMIMETypes: [], suggestedName: ""
      ) { [weak self] urls in
        completionHandler(urls.isEmpty ? nil : urls)
        self?.pruneFinishedPrompts()
      }
      present(.fileChooser(prompt))
    }
  #endif

  func webView(
    _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
    decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
  ) {
    let permissions: BrowserPermissions =
      switch type {
      case .camera: .camera
      case .microphone: .microphone
      case .cameraAndMicrophone: [.camera, .microphone]
      @unknown default: .other
      }
    let prompt = BrowserPermissionPrompt(
      origin: BrowserPermissionStore.origin(of: Self.originURL(origin)), permissions: permissions
    ) { [weak self] answer in
      decisionHandler(answer == .allow ? .grant : .deny)
      self?.pruneFinishedPrompts()
    }
    present(.permission(prompt))
  }

  /// window.open and target=_blank: a new tab on WebKit's configuration, so `window.opener`
  /// works.
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    let url = navigationAction.request.url
    if popupPolicy == .block {
      blockPopup(url: url, reason: "Popups are blocked for this tab.")
      return nil
    }
    if let urlPolicy, let url, case .deny(let reason) = urlPolicy.evaluate(url) {
      state.lastError = .navigationBlocked(url: url, reason: reason)
      return nil
    }
    guard let delegate else {
      blockPopup(url: url, reason: "No tab delegate shows popups.")
      return nil
    }
    let popup = SystemBrowserTab(profile: profile, configuration: configuration)
    popup.popupPolicy = popupPolicy
    popup.urlPolicy = urlPolicy
    var size: CGSize?
    if let width = windowFeatures.width?.doubleValue,
      let height = windowFeatures.height?.doubleValue
    {
      size = CGSize(width: width, height: height)
    }
    let disposition: BrowserPopupDisposition =
      size != nil || windowFeatures.toolbarsVisibility?.boolValue == false ? .popup : .foregroundTab
    delegate.tab(
      self,
      didOpen: BrowserPopup(
        tab: popup, opener: self, targetURL: url, disposition: disposition, requestedSize: size))
    return popup.webView
  }

  func webViewDidClose(_ webView: WKWebView) {
    close()  // window.close() from the page; the app's window or tab observes `isClosed`.
  }

  private func blockPopup(url: URL?, reason: String) {
    let blocked = BrowserBlockedPopup(url: url, reason: reason)
    state.lastBlockedPopup = blocked
    delegate?.tab(self, didBlock: blocked)
  }

  static func originURL(_ origin: WKSecurityOrigin) -> URL? {
    var components = URLComponents()
    components.scheme = origin.protocol
    components.host = origin.host
    components.port = origin.port == 0 ? nil : origin.port
    return components.url
  }
}
