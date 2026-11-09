import Foundation
import OmnigentViewTesting
import Security
import Testing
import WebKit

@testable import OmnigentBrowser

@MainActor
@Suite("System tab navigation decisions", .serialized)
struct SystemTabNavigationTests {
  private func decide(_ tab: SystemBrowserTab, _ action: WKNavigationAction)
    -> WKNavigationActionPolicy?
  {
    var decided: WKNavigationActionPolicy?
    tab.webView(tab.webView, decidePolicyFor: action) { decided = $0 }
    return decided
  }

  @Test("a page goes through; a download link becomes a download; a refused host is reported")
  func actionPolicy() throws {
    let fixture = try SystemTabFixture()
    let page = try testURL("https://a.example/")
    #expect(decide(fixture.tab, FakeNavigationAction(url: page)) == .allow)
    #expect(
      decide(fixture.tab, FakeNavigationAction(url: page, shouldDownload: true)) == .download)
    fixture.tab.urlPolicy = RefusingPolicy(host: "a.example")
    #expect(decide(fixture.tab, FakeNavigationAction(url: page)) == .cancel)
    #expect(fixture.tab.state.lastError == .navigationBlocked(url: page, reason: "not here"))
    fixture.tab.urlPolicy = RefusingPolicy(host: "other.example")
    #expect(decide(fixture.tab, FakeNavigationAction(url: page)) == .allow)
  }

  @Test("a link to another app is cancelled here and confirmed before it opens")
  func externalLink() async throws {
    let fixture = try SystemTabFixture()
    SystemSideEffects.reset()
    let link = try testURL("mailto:a@example.com")
    #expect(decide(fixture.tab, FakeNavigationAction(url: link)) == .cancel)
    guard case .dialog(let dialog)? = fixture.delegate.requested.first else {
      Issue.record("expected a confirmation")
      return
    }
    #expect(dialog.message.contains("mailto:"))
    #expect(SystemSideEffects.record.openedURLs.isEmpty)
    dialog.accept()
    #expect(try await waitUntil { SystemSideEffects.record.openedURLs == [link] })
  }

  @Test("a page the browser can't show, or marked as an attachment, downloads; others show")
  func responsePolicy() throws {
    let fixture = try SystemTabFixture()
    let url = try testURL("https://a.example/file")
    func decide(_ response: WKNavigationResponse) -> WKNavigationResponsePolicy? {
      var decided: WKNavigationResponsePolicy?
      fixture.tab.webView(fixture.tab.webView, decidePolicyFor: response) { decided = $0 }
      return decided
    }
    let plain = try #require(
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    let attachment = try #require(
      HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Disposition": "Attachment; filename=a.zip"]))
    #expect(decide(FakeNavigationResponse(response: plain)) == .allow)
    #expect(decide(FakeNavigationResponse(response: attachment)) == .download)
    #expect(decide(FakeNavigationResponse(response: plain, canShow: false)) == .download)
    #expect(decide(FakeNavigationResponse(response: attachment, mainFrame: false)) == .allow)
  }

  @Test("failures are reported with their address; a stop and a cancelled download aren't errors")
  func failures() throws {
    let fixture = try SystemTabFixture()
    let tab = fixture.tab
    let url = try testURL("https://down.example/")
    let failed = NSError(
      domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
      userInfo: [NSURLErrorFailingURLErrorKey: url])
    tab.webView(tab.webView, didFailProvisionalNavigation: nil, withError: failed)
    guard case .navigationFailed(let reported, _, _)? = tab.state.lastError else {
      Issue.record("expected a failure, got \(String(describing: tab.state.lastError))")
      return
    }
    #expect(reported == url)
    tab.webView(tab.webView, didStartProvisionalNavigation: nil)
    #expect(tab.state.lastError == nil)
    tab.webView(tab.webView, didFail: nil, withError: failed)
    #expect(tab.state.lastError != nil)

    let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    tab.webView(tab.webView, didFail: nil, withError: cancelled)
    #expect(tab.state.lastError == .navigationCancelled(url: nil))
    tab.state.lastError = nil
    let policy = NSError(
      domain: WKErrorDomain, code: SystemBrowserTab.frameLoadInterruptedByPolicyChange)
    tab.webView(tab.webView, didFail: nil, withError: policy)
    #expect(tab.state.lastError == nil)

    tab.webViewWebContentProcessDidTerminate(tab.webView)
    guard case .contentProcessTerminated? = tab.state.lastError else {
      Issue.record("expected a terminated process")
      return
    }
  }
}

@MainActor
@Suite("System tab sign-in and certificate challenges", .serialized)
struct SystemTabChallengeTests {
  private struct Answer {
    var disposition: URLSession.AuthChallengeDisposition?
    var credential: URLCredential?
  }

  private func challenge(_ space: URLProtectionSpace) -> URLAuthenticationChallenge {
    URLAuthenticationChallenge(
      protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
      failureResponse: nil, error: nil, sender: SilentChallengeSender())
  }

  private func receive(_ space: URLProtectionSpace, on tab: SystemBrowserTab) -> () -> Answer {
    let box = AnswerBox()
    tab.webView(tab.webView, didReceive: challenge(space)) { disposition, credential in
      box.answer = Answer(disposition: disposition, credential: credential)
    }
    return { box.answer }
  }

  private final class AnswerBox {
    var answer = Answer()
  }

  @Test("HTTP sign-in becomes a prompt; its answer signs in or cancels, and leaves the queue")
  func httpAuth() throws {
    let fixture = try SystemTabFixture()
    let space = FakeProtectionSpace(method: NSURLAuthenticationMethodHTTPBasic)
    let signedIn = receive(space, on: fixture.tab)
    guard case .authentication(let prompt)? = fixture.delegate.requested.last else {
      Issue.record("expected a sign-in prompt")
      return
    }
    #expect(prompt.space.host == "a.example")
    #expect(prompt.space.port == 8443)
    #expect(prompt.space.isSecure)
    #expect(signedIn().disposition == nil)
    prompt.respond(BrowserCredential(username: "user", password: "test-password"))
    #expect(signedIn().disposition == .useCredential)
    #expect(signedIn().credential?.user == "user")
    #expect(signedIn().credential?.persistence == URLCredential.Persistence.none)
    #expect(fixture.tab.state.pendingPrompts.isEmpty)

    let cancelled = receive(space, on: fixture.tab)
    guard case .authentication(let second)? = fixture.delegate.requested.last else {
      Issue.record("expected a sign-in prompt")
      return
    }
    second.cancel()
    #expect(cancelled().disposition == .cancelAuthenticationChallenge)
  }

  @Test("challenges this tab doesn't handle go to WebKit")
  func defaultHandling() throws {
    let fixture = try SystemTabFixture()
    let clientCertificate = FakeProtectionSpace(
      method: NSURLAuthenticationMethodClientCertificate)
    #expect(receive(clientCertificate, on: fixture.tab)().disposition == .performDefaultHandling)
    let noTrust = FakeProtectionSpace(method: NSURLAuthenticationMethodServerTrust)
    #expect(receive(noTrust, on: fixture.tab)().disposition == .performDefaultHandling)
    #expect(fixture.delegate.requested.isEmpty)
  }

  @Test("an untrusted certificate asks; proceeding is remembered and cancelling is not")
  func untrustedCertificate() throws {
    let fixture = try SystemTabFixture()
    let trust = try UntrustedCertificate.trust()
    let space = FakeProtectionSpace(method: NSURLAuthenticationMethodServerTrust, trust: trust)
    let cancelled = receive(space, on: fixture.tab)
    guard case .certificateError(let first)? = fixture.delegate.requested.last else {
      Issue.record("expected a certificate prompt")
      return
    }
    #expect(first.subject == "omnigent.test")
    #expect(first.url?.absoluteString == "https://a.example:8443")
    #expect(first.isOverridable)
    first.cancel()
    #expect(cancelled().disposition == .cancelAuthenticationChallenge)
    #expect(fixture.tab.certificateExceptions.isEmpty)

    let proceeded = receive(space, on: fixture.tab)
    guard case .certificateError(let second)? = fixture.delegate.requested.last else {
      Issue.record("expected a certificate prompt")
      return
    }
    try second.proceed()
    #expect(proceeded().disposition == .useCredential)

    let count = fixture.delegate.requested.count
    let remembered = receive(space, on: fixture.tab)
    #expect(remembered().disposition == .useCredential)
    #expect(fixture.delegate.requested.count == count)
  }
}
