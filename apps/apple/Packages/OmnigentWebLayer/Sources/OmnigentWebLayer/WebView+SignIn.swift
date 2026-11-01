public import Foundation
internal import OWLProtocol

/// A navigation to a scheme the engine does not handle, such as Okta Verify's
/// `com-okta-authenticator:` (protocol 1.3). The host never opens it; the app decides.
nonisolated public struct WebExternalURLRequest: Sendable, Hashable {
  /// The URL to hand to the OS.
  public let url: URL
  /// The frame that navigated, when known.
  public let origin: URL?

  /// Creates a request.
  public init(url: URL, origin: URL?) {
    self.url = url
    self.origin = origin
  }
}

/// Protocol 1.3 sign-in plumbing. See DESIGN.md, "Sign-in (protocol 1.3)".
extension WebView {
  func handleSignIn(_ kind: OWLMessageKind, _ fields: WireDecoder) -> Bool {
    guard kind == .externalProtocol else { return false }
    guard let url = fields.string(.URL).flatMap(URL.init(string:)) else {
      let detail = "The host sent an external URL that does not parse."
      lastError = .featureBlocked(feature: "Opening an external application", detail: detail)
      onEvent?(.featureBlocked(feature: "Opening an external application", detail: detail))
      return true
    }
    let request = WebExternalURLRequest(
      url: url, origin: fields.string(.origin).flatMap(URL.init(string:)))
    if let uiDelegate {
      uiDelegate.webView(self, wantsToOpenExternally: request)
    } else {
      reportUnhandledExternalURL(request)
    }
    return true
  }

  /// Records that nothing opened `request`.
  func reportUnhandledExternalURL(_ request: WebExternalURLRequest) {
    let feature = "Opening an external application"
    let detail = "Nothing handled \(request.url.scheme ?? "the"): link in view \(id)."
    lastError = .featureBlocked(feature: feature, detail: detail)
    onEvent?(.featureBlocked(feature: feature, detail: detail))
  }
}
