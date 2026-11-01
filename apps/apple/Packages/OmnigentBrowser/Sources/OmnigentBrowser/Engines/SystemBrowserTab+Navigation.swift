internal import Foundation
internal import Security
internal import WebKit

/// Navigation on WebKit: the URL policy for every navigation, downloads through `WKDownload`,
/// HTTP authentication and certificate errors as engine-neutral prompts.
extension SystemBrowserTab: WKNavigationDelegate {
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
    state.lastError = nil
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
    mainFrameCommitted()
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?,
    withError error: any Error
  ) {
    let failingURL = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
    report(error, url: failingURL ?? webView.url)
  }

  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error
  ) {
    report(error, url: webView.url)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    state.lastError = .contentProcessTerminated(reason: "WebKit web content process exited.")
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    if let url = navigationAction.request.url, let urlPolicy,
      case .deny(let reason) = urlPolicy.evaluate(url)
    {
      state.lastError = .navigationBlocked(url: url, reason: reason)
      decisionHandler(.cancel)
      return
    }
    if let url = navigationAction.request.url, let scheme = url.scheme,
      !WKWebView.handlesURLScheme(scheme), BrowserExternalApplication.isExternal(url)
    {
      // WebKit would fail with "unsupported URL"; offer the registered app instead.
      decisionHandler(.cancel)
      BrowserExternalApplication.request(
        url, origin: navigationAction.sourceFrame.request.url, from: self, delegate: delegate)
      return
    }
    decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
  ) {
    let response = navigationResponse.response as? HTTPURLResponse
    let attachment =
      response?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased()
      .hasPrefix("attachment") == true
    if navigationResponse.isForMainFrame, attachment || !navigationResponse.canShowMIMEType {
      decisionHandler(.download)
      return
    }
    decisionHandler(.allow)
  }

  func webView(
    _ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload
  ) {
    track(download)
  }

  func webView(
    _ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload
  ) {
    track(download)
  }

  private func track(_ download: WKDownload) {
    let tracker = SystemDownloadTracker(tab: self, download: download)
    downloadTrackers[ObjectIdentifier(download)] = tracker
    download.delegate = tracker
  }

  func webView(
    _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let space = challenge.protectionSpace
    switch space.authenticationMethod {
    case NSURLAuthenticationMethodServerTrust:
      serverTrust(challenge, completionHandler: completionHandler)
    case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
      NSURLAuthenticationMethodDefault, NSURLAuthenticationMethodNTLM:
      let prompt = BrowserAuthPrompt(
        space: BrowserProtectionSpace(
          host: space.host, port: space.port, realm: space.realm ?? "",
          scheme: space.authenticationMethod, isProxy: space.isProxy(),
          isSecure: space.protocol == "https")
      ) { [weak self] credential in
        if let credential {
          // `.none`: URLCredentialStorage never keeps it; the Keychain only on opt-in.
          completionHandler(
            .useCredential,
            URLCredential(
              user: credential.username, password: credential.password, persistence: .none))
        } else {
          completionHandler(.cancelAuthenticationChallenge, nil)
        }
        self?.pruneFinishedPrompts()
      }
      present(.authentication(prompt))
    default:
      completionHandler(.performDefaultHandling, nil)
    }
  }

  /// Certificate errors: evaluate the trust; an untrusted server becomes an interstitial prompt.
  private func serverTrust(
    _ challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let space = challenge.protectionSpace
    guard let trust = space.serverTrust else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    var error: CFError?
    if SecTrustEvaluateWithError(trust, &error) {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    let exception = "\(space.host):\(space.port)"
    if certificateExceptions.contains(exception) {
      completionHandler(.useCredential, URLCredential(trust: trust))
      return
    }
    let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
    let summary = chain.first.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? ""
    let issuer = chain.dropFirst().first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
    var components = URLComponents()
    components.scheme = "https"
    components.host = space.host
    components.port = space.port == 443 ? nil : space.port
    let trustError = error.map { $0 as any Error as NSError }
    let prompt = BrowserCertificatePrompt(
      url: components.url,
      message: trustError?.localizedDescription ?? "The certificate is not trusted.",
      errorCode: trustError?.code ?? Int(errSecNotTrusted),
      subject: summary, issuer: issuer ?? summary, isOverridable: true
    ) { [weak self] proceed in
      if proceed {
        self?.certificateExceptions.insert(exception)
        completionHandler(.useCredential, URLCredential(trust: trust))
      } else {
        completionHandler(.cancelAuthenticationChallenge, nil)
      }
      self?.pruneFinishedPrompts()
    }
    present(.certificateError(prompt))
  }
}

/// Follows one `WKDownload`: asks for the destination, then reports progress.
final class SystemDownloadTracker: NSObject, WKDownloadDelegate {
  private weak var tab: SystemBrowserTab?
  private let download: WKDownload
  private var record: BrowserDownload?
  private var progressObservation: NSKeyValueObservation?

  init(tab: SystemBrowserTab, download: WKDownload) {
    self.tab = tab
    self.download = download
  }

  func download(
    _ download: WKDownload, decideDestinationUsing response: URLResponse,
    suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
  ) {
    guard let tab else {
      completionHandler(nil)
      return
    }
    let total = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
    let prompt = BrowserDownloadPrompt(
      url: response.url, suggestedName: suggestedFilename, mimeType: response.mimeType ?? "",
      totalBytes: total
    ) { [weak self, weak tab] destination in
      completionHandler(destination)
      tab?.pruneFinishedPrompts()
      guard let self, let destination else {
        self?.finish()
        return
      }
      self.started(destination: destination, response: response, name: suggestedFilename)
    }
    tab.present(.download(prompt))
  }

  private func started(destination: URL, response: URLResponse, name: String) {
    guard let tab else { return }
    let download = download
    let record = BrowserDownload(
      url: response.url, suggestedName: name, destination: destination, engine: .system,
      totalBytes: response.expectedContentLength >= 0 ? response.expectedContentLength : nil
    ) {
      download.cancel { _ in }  // Resume data is not kept; a cancelled download restarts.
    }
    self.record = record
    // Progress can change on any thread; the record is updated on the main actor.
    progressObservation = download.progress.observe(
      \.completedUnitCount, options: [.new], changeHandler: Self.progressHandler(self))
    tab.delegate?.tab(tab, didStart: record)
  }

  private static func progressHandler(_ tracker: SystemDownloadTracker)
    -> @Sendable (Progress, NSKeyValueObservedChange<Int64>) -> Void
  {
    { [weak tracker] progress, _ in
      let completed = progress.completedUnitCount
      let total = progress.totalUnitCount
      Task { @MainActor in
        tracker?.record?.receivedBytes = completed
        if total > 0 { tracker?.record?.totalBytes = total }
      }
    }
  }

  func downloadDidFinish(_ download: WKDownload) {
    record?.receivedBytes = record?.totalBytes ?? record?.receivedBytes ?? 0
    record?.state = .complete
    finish()
  }

  func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
    let nsError = error as NSError
    record?.state =
      nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
      ? .cancelled : .failed(error.localizedDescription)
    if record == nil {
      tab?.state.lastError = .downloadFailed(error.localizedDescription)
    }
    finish()
  }

  private func finish() {
    progressObservation = nil
    tab?.downloadTrackers[ObjectIdentifier(download)] = nil
  }
}
