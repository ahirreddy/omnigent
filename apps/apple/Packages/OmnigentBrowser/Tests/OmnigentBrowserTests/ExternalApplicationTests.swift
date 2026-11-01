import Foundation
import Testing

@testable import OmnigentBrowser

@MainActor
final class RecordingTabDelegate: BrowserTabDelegate {
  var prompts: [BrowserPrompt] = []

  func tab(_ tab: any BrowserTab, didRequest prompt: BrowserPrompt) { prompts.append(prompt) }
  func tab(_ tab: any BrowserTab, didCancel prompt: BrowserPrompt) {}
  func tab(_ tab: any BrowserTab, didOpen popup: BrowserPopup) {}
  func tab(_ tab: any BrowserTab, didBlock popup: BrowserBlockedPopup) {}
  func tab(_ tab: any BrowserTab, didStart download: BrowserDownload) {}
}

@MainActor
@Suite("External applications")
struct ExternalApplicationTests {
  private func url(_ string: String) throws -> URL { try #require(URL(string: string)) }

  @Test func onlyNonWebSchemesLeaveTheBrowser() throws {
    let okta = try url("com-okta-authenticator:/deviceChallenge")
    #expect(BrowserExternalApplication.isExternal(okta))
    #expect(BrowserExternalApplication.isExternal(try url("zoommtg://join")))
    let webURLs = [
      "https://a.example/", "http://a.example/", "file:///tmp/x", "javascript:1",
      "data:text/plain,x", "about:blank", "blob:https://a.example/1",
    ]
    for webURL in webURLs {
      #expect(!BrowserExternalApplication.isExternal(try url(webURL)), "\(webURL)")
    }
  }

  @Test func messageNamesTheAppWhenKnown() {
    #expect(
      BrowserExternalApplication.message(appName: "Okta Verify", scheme: "com-okta-authenticator")
        == "This page wants to open a com-okta-authenticator: link in Okta Verify.")
    #expect(
      BrowserExternalApplication.message(appName: nil, scheme: "zoommtg")
        == "This page wants to open a zoommtg: link in another app.")
  }

  @Test func webSchemesAreRefusedWithoutAsking() throws {
    let tab = FakeTab(kind: .chromium, profile: .ephemeral("external"), initialURL: nil)
    let delegate = RecordingTabDelegate()
    BrowserExternalApplication.request(
      try url("https://a.example/"), origin: nil, from: tab, delegate: delegate)
    #expect(delegate.prompts.isEmpty)
    guard case .featureUnsupported? = tab.state.lastError else {
      Issue.record("expected featureUnsupported, got \(String(describing: tab.state.lastError))")
      return
    }
  }

  #if os(macOS)
    @Test func schemesWithoutAnAppAreReported() throws {
      let tab = FakeTab(kind: .chromium, profile: .ephemeral("external"), initialURL: nil)
      let delegate = RecordingTabDelegate()
      BrowserExternalApplication.request(
        try url("omnigent-unregistered-test-scheme:x"), origin: nil, from: tab, delegate: delegate)
      #expect(delegate.prompts.isEmpty)
      guard case .featureUnsupported(let feature, _)? = tab.state.lastError else {
        Issue.record("expected featureUnsupported, got \(String(describing: tab.state.lastError))")
        return
      }
      #expect(feature.contains("No app opens"))
    }

    @Test func registeredSchemesAskAndDeclineWithoutOpening() throws {
      let tab = FakeTab(kind: .system, profile: .ephemeral("external"), initialURL: nil)
      let delegate = RecordingTabDelegate()
      // Every Mac registers an app for mailto:.
      BrowserExternalApplication.request(
        try url("mailto:owl@example.com"), origin: try url("https://a.example/"), from: tab,
        delegate: delegate)
      guard case .dialog(let dialog)? = delegate.prompts.first else {
        Issue.record("expected a confirmation, got \(delegate.prompts)")
        return
      }
      #expect(dialog.kind == .confirm)
      #expect(dialog.message.hasPrefix("This page wants to open a mailto: link in "))
      #expect(tab.state.pendingPrompts.count == 1)
      dialog.cancel()
      #expect(tab.state.pendingPrompts.isEmpty)
      #expect(tab.state.lastError == nil)
    }
  #endif

  @Test func localNetworkHasItsOwnName() {
    #expect(BrowserPermissions.localNetwork.rawValue == 1 << 7)
    #expect(BrowserPermissions.localNetwork.names.count == 1)
    #expect(!BrowserPermissions.localNetwork.contains(.other))
  }
}
