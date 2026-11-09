import Foundation
import OmnigentViewTesting
import Testing
import WebKit

@testable import OmnigentBrowser

/// Hands over the frame of a real page, which WebKit won't let a test build.
@MainActor
private final class FrameCatcher: NSObject, WKUIDelegate {
  var frame: WKFrameInfo?

  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    self.frame = frame
    completionHandler()
  }

  static func frameOfPage(at base: String) async throws -> (WKFrameInfo, WKWebView) {
    let webView = WKWebView()
    let catcher = FrameCatcher()
    webView.uiDelegate = catcher
    webView.loadHTMLString("<p>page</p>", baseURL: URL(string: base))
    #expect(try await waitUntil { webView.url != nil && !webView.isLoading })
    _ = try await webView.evaluateJavaScript("alert('hello'); 1")
    #expect(try await waitUntil { catcher.frame != nil })
    return (try #require(catcher.frame), webView)
  }
}

@MainActor
@Suite("System tab page prompts", .serialized)
struct SystemTabPromptTests {
  @Test("a page's alert, confirm and prompt wait for the answer and return it to the page")
  func javaScriptDialogs() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    try await fixture.load("<p>page</p>")
    let answers = PromptAnswers()
    fixture.delegate.onPrompt = { prompt in
      guard case .dialog(let dialog) = prompt else { return }
      answers.seen.append(dialog)
      switch (dialog.kind, answers.accept) {
      case (.prompt, true): dialog.accept(text: answers.text)
      case (_, true): dialog.accept()
      case (_, false): dialog.cancel()
      }
    }
    _ = try await fixture.tab.evaluateJavaScript("alert('careful')")
    #expect(answers.seen.last?.kind == .alert)
    #expect(answers.seen.last?.message == "careful")
    #expect(answers.seen.last?.origin?.host == "a.example")

    let agreed = try await fixture.tab.evaluateJavaScript("confirm('really?')")
    #expect(agreed == .bool(true))
    #expect(answers.seen.last?.kind == .confirm)

    answers.text = "typed"
    let typed = try await fixture.tab.evaluateJavaScript("prompt('name?', 'initial')")
    #expect(typed == .string("typed"))
    #expect(answers.seen.last?.defaultText == "initial")
    answers.text = nil
    let kept = try await fixture.tab.evaluateJavaScript("prompt('name?', 'initial')")
    #expect(kept == .string("initial"))

    answers.accept = false
    let refused = try await fixture.tab.evaluateJavaScript("confirm('really?')")
    #expect(refused == .bool(false))
    let dismissed = try await fixture.tab.evaluateJavaScript("prompt('name?') === null")
    #expect(dismissed == .bool(true))
    #expect(fixture.tab.state.pendingPrompts.isEmpty)
  }

  @Test("a file input asks for the right kind of choice and gets back what was chosen")
  func openPanel() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    let (frame, keepAlive) = try await FrameCatcher.frameOfPage(at: "https://a.example/")
    defer { withExtendedLifetime(keepAlive) {} }
    let cases: [(FakeOpenPanelParameters, BrowserFileChooserMode)] = [
      (FakeOpenPanelParameters(), .open),
      (FakeOpenPanelParameters(multiple: true), .openMultiple),
      (FakeOpenPanelParameters(directories: true, multiple: true), .openFolder),
    ]
    let chosen = [URL(filePath: "/tmp/a.txt")]
    for (parameters, mode) in cases {
      var answered: [URL] = []
      fixture.tab.webView(
        fixture.tab.webView, runOpenPanelWith: parameters, initiatedByFrame: frame
      ) { answered = $0 ?? [] }
      guard case .fileChooser(let chooser)? = fixture.delegate.requested.last else {
        Issue.record("expected a file chooser")
        return
      }
      #expect(chooser.mode == mode)
      chooser.choose(chosen)
      #expect(answered == chosen)
    }
    var cancelled = false
    fixture.tab.webView(
      fixture.tab.webView, runOpenPanelWith: FakeOpenPanelParameters(), initiatedByFrame: frame
    ) { cancelled = $0 == nil }
    guard case .fileChooser(let chooser)? = fixture.delegate.requested.last else {
      Issue.record("expected a file chooser")
      return
    }
    chooser.cancel()
    #expect(cancelled)
    #expect(fixture.tab.state.pendingPrompts.isEmpty)
  }

  @Test("camera and microphone requests name what's asked for and pass on the answer")
  func mediaCapture() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    let (frame, keepAlive) = try await FrameCatcher.frameOfPage(at: "https://a.example:8443/")
    defer { withExtendedLifetime(keepAlive) {} }
    let cases: [(WKMediaCaptureType, BrowserPermissions)] = [
      (.camera, .camera), (.microphone, .microphone),
      (.cameraAndMicrophone, [.camera, .microphone]),
    ]
    for (type, permissions) in cases {
      var decision: WKPermissionDecision?
      fixture.tab.webView(
        fixture.tab.webView, requestMediaCapturePermissionFor: frame.securityOrigin,
        initiatedByFrame: frame, type: type
      ) { decision = $0 }
      guard case .permission(let prompt)? = fixture.delegate.requested.last else {
        Issue.record("expected a permission prompt")
        return
      }
      #expect(prompt.permissions == permissions)
      #expect(prompt.origin.contains("a.example"))
      #expect(prompt.origin.contains("8443"))
      if type == .camera {
        prompt.allow()
        #expect(decision == .grant)
      } else {
        prompt.deny()
        #expect(decision == .deny)
      }
    }
    #expect(fixture.tab.state.pendingPrompts.isEmpty)
  }

  @Test("with nobody to ask, every kind of prompt is refused and the page isn't left waiting")
  func noDelegateDeniesEveryPrompt() throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    fixture.tab.delegate = nil
    var answers: [String] = []
    let prompts: [BrowserPrompt] = [
      .dialog(
        BrowserDialogPrompt(kind: .alert, origin: nil, message: "m", defaultText: "") { _, _ in
          answers.append("dialog")
        }),
      .permission(
        BrowserPermissionPrompt(origin: "o", permissions: .camera) { answer in
          answers.append("permission \(answer)")
        }),
      .fileChooser(
        BrowserFileChooserPrompt(
          mode: .open, allowedExtensions: [], allowedMIMETypes: [], suggestedName: ""
        ) { answers.append("files \($0.count)") }),
      .download(
        BrowserDownloadPrompt(url: nil, suggestedName: "f", mimeType: "", totalBytes: nil) {
          answers.append("download \($0 == nil)")
        }),
      .authentication(
        BrowserAuthPrompt(
          space: BrowserProtectionSpace(
            host: "h", port: 1, realm: "", scheme: "", isProxy: false, isSecure: true)
        ) { answers.append("auth \($0 == nil)") }),
      .certificateError(
        BrowserCertificatePrompt(
          url: nil, message: "", errorCode: 0, subject: "", issuer: "", isOverridable: true
        ) { answers.append("certificate \($0)") }),
      .color(BrowserColorPrompt(initialColor: "#000000") { answers.append("color \($0 == nil)") }),
    ]
    for prompt in prompts {
      fixture.tab.present(prompt)
      guard case .featureUnsupported(let feature, .system)? = fixture.tab.state.lastError else {
        Issue.record("expected the refusal to be reported")
        return
      }
      #expect(feature.contains(prompt.kindName))
    }
    #expect(
      answers == [
        "dialog", "permission deny", "files 0", "download true", "auth true", "certificate false",
        "color true",
      ])
  }

  @Test("closing a tab while its page waits on an alert doesn't take the app down")
  func closingWithAnOpenAlert() async throws {
    let fixture = try SystemTabFixture()
    try await fixture.load("<p>page</p>")
    var scriptEnded = false
    let tab = fixture.tab
    Task {
      do {
        _ = try await tab.evaluateJavaScript("alert('wait'); 1")
      } catch {
        Issue.record("the script should end normally: \(error)")
      }
      scriptEnded = true
    }
    #expect(try await waitUntil { !fixture.delegate.requested.isEmpty })
    fixture.tab.close()
    fixture.delegate.requested.removeAll()
    fixture.delegate.cancelled.removeAll()
    #expect(try await waitUntil(timeout: .seconds(3)) { scriptEnded })
  }

  @Test("closing a tab withdraws what it asked and tells the app")
  func closingWithdraws() throws {
    let fixture = try SystemTabFixture()
    let space = FakeProtectionSpace(method: NSURLAuthenticationMethodHTTPBasic)
    let challenge = URLAuthenticationChallenge(
      protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
      failureResponse: nil, error: nil, sender: SilentChallengeSender())
    var disposition: URLSession.AuthChallengeDisposition?
    fixture.tab.webView(fixture.tab.webView, didReceive: challenge) { answer, _ in
      disposition = answer
    }
    #expect(fixture.tab.state.pendingPrompts.count == 1)
    fixture.tab.close()
    #expect(fixture.delegate.cancelled.count == 1)
    #expect(fixture.tab.state.pendingPrompts.isEmpty)
    #expect(disposition == .cancelAuthenticationChallenge)
    #expect(fixture.tab.state.isClosed)
    fixture.tab.close()
    #expect(fixture.delegate.cancelled.count == 1)
  }
}

@MainActor
private final class PromptAnswers {
  var seen: [BrowserDialogPrompt] = []
  var accept = true
  var text: String?
}

@MainActor
@Suite("System tab popups", .serialized)
struct SystemTabPopupTests {
  private func open(
    _ fixture: SystemTabFixture, url: String = "https://a.example/popup",
    features: WKWindowFeatures = FakeWindowFeatures()
  ) throws -> WKWebView? {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let action = FakeNavigationAction(url: try testURL(url))
    return fixture.tab.webView(
      fixture.tab.webView, createWebViewWith: configuration, for: action, windowFeatures: features)
  }

  @Test("a tab that blocks popups says what it blocked")
  func blocked() throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    fixture.tab.popupPolicy = .block
    #expect(try open(fixture) == nil)
    #expect(fixture.delegate.blocked.first?.url?.absoluteString == "https://a.example/popup")
    #expect(fixture.tab.state.lastBlockedPopup?.reason.contains("blocked") == true)
    #expect(!fixture.tab.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
    fixture.tab.popupPolicy = .allow
    #expect(fixture.tab.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
  }

  @Test("a popup to a refused address doesn't open")
  func refusedAddress() throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    fixture.tab.urlPolicy = RefusingPolicy(host: "a.example")
    #expect(try open(fixture) == nil)
    #expect(fixture.delegate.opened.isEmpty)
    guard case .navigationBlocked(_, let reason)? = fixture.tab.state.lastError else {
      Issue.record("expected a blocked navigation")
      return
    }
    #expect(reason == "not here")
  }

  @Test("with nobody to show it, a popup is blocked")
  func noDelegate() throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    fixture.tab.delegate = nil
    #expect(try open(fixture) == nil)
    #expect(fixture.tab.state.lastBlockedPopup?.reason.contains("No tab delegate") == true)
  }

  @Test("a link opens as a tab; a sized or toolbarless window opens as a popup")
  func dispositions() throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    fixture.tab.urlPolicy = RefusingPolicy(host: "other.example")
    #expect(try open(fixture) != nil)
    let link = try #require(fixture.delegate.opened.last)
    #expect(link.disposition == .foregroundTab)
    #expect(link.requestedSize == nil)
    #expect(link.targetURL?.absoluteString == "https://a.example/popup")
    #expect((link.tab as? SystemBrowserTab)?.urlPolicy != nil)
    #expect(link.opener === fixture.tab)

    let size = CGSize(width: 300, height: 200)
    #expect(try open(fixture, features: FakeWindowFeatures(size: size)) != nil)
    #expect(fixture.delegate.opened.last?.disposition == .popup)
    #expect(fixture.delegate.opened.last?.requestedSize == size)

    #expect(try open(fixture, features: FakeWindowFeatures(toolbars: false)) != nil)
    #expect(fixture.delegate.opened.last?.disposition == .popup)
    #expect(try open(fixture, features: FakeWindowFeatures(toolbars: true)) != nil)
    #expect(fixture.delegate.opened.last?.disposition == .foregroundTab)
  }

  @Test("a page closing its own window closes the tab")
  func pageClosesItself() throws {
    let fixture = try SystemTabFixture()
    fixture.tab.webViewDidClose(fixture.tab.webView)
    #expect(fixture.tab.state.isClosed)
    #expect(fixture.tab.webView.uiDelegate == nil)
  }
}
