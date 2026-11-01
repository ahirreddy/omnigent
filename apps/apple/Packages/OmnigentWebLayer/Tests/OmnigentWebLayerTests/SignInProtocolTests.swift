import Foundation
import OWLProtocol
import Testing

@testable import OmnigentWebLayer

@MainActor
final class ExternalURLRecorder: WebViewUIDelegate {
  var external: [WebExternalURLRequest] = []

  func webView(_ webView: WebView, didRequest prompt: WebPrompt) {}
  func webView(_ webView: WebView, didCancel prompt: WebPrompt, reason: String) {}
  func webView(_ webView: WebView, didOpen popup: WebPopup) {}
  func webView(_ webView: WebView, didBlock popup: WebBlockedPopup) {}
  func webView(_ webView: WebView, wantsToOpenExternally request: WebExternalURLRequest) {
    external.append(request)
  }
}

@MainActor
@Suite("Protocol 1.3 sign-in plumbing")
struct SignInProtocolTests {
  @Test func numberingIsStable() {
    #expect(OWL_PROTOCOL_MINOR_SIGN_IN == 3)
    #expect(OWLMessageKind.externalProtocol.rawValue == 130)
    #expect(OWLPermission.localNetwork.rawValue == 1 << 7)
    #expect(WebPermissions.localNetwork.rawValue == OWLPermission.localNetwork.rawValue)
  }

  @Test func localNetworkPermissionReachesTheDelegate() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(
      .permissionRequest,
      WireEncoder().u64(.promptID, 7).string(.origin, "https://example.okta.com")
        .u64(.permissions, OWLPermission.localNetwork.rawValue))
    guard case .permission(let request)? = fixture.recorder.requested.first else {
      Issue.record("expected a permission prompt, got \(fixture.recorder.requested)")
      return
    }
    #expect(request.permissions == .localNetwork)
    request.allow()
    let reply = try #require(fixture.last(.permissionReply))
    #expect(reply.u64(.permissionResult) == OWLPermissionResult.allow.rawValue)
    #expect(reply.u64(.permissions) == OWLPermission.localNetwork.rawValue)
  }

  @Test func externalProtocolGoesToTheDelegate() throws {
    let fixture = ProtocolFixture()
    let recorder = ExternalURLRecorder()
    fixture.webView.uiDelegate = recorder
    try fixture.receive(
      .externalProtocol,
      WireEncoder().string(.URL, "com-okta-authenticator:/deviceChallenge?challengeRequest=x")
        .string(.origin, "https://example.okta.com/signin"))
    let request = try #require(recorder.external.first)
    #expect(request.url.scheme == "com-okta-authenticator")
    #expect(request.origin?.host == "example.okta.com")
    #expect(fixture.webView.lastError == nil)
  }

  @Test func delegatesWithoutHandlingReportItBlocked() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(.externalProtocol, WireEncoder().string(.URL, "zoommtg://join?confno=1"))
    guard case .featureBlocked(let feature, _)? = fixture.webView.lastError else {
      Issue.record("expected featureBlocked, got \(String(describing: fixture.webView.lastError))")
      return
    }
    #expect(feature == "Opening an external application")
  }

  @Test func unparsableExternalURLIsReported() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(.externalProtocol, WireEncoder().string(.URL, ""))
    guard case .featureBlocked? = fixture.webView.lastError else {
      Issue.record("expected featureBlocked, got \(String(describing: fixture.webView.lastError))")
      return
    }
  }
}
