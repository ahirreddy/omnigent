import Foundation
import OmnigentViewTesting
import Security
import Testing
import WebKit

@testable import OmnigentBrowser

/// WebKit's dealloc destroys an internal object a subclass never built, so a fake must never die.
private func keepAlive(_ fake: NSObject) { _ = Unmanaged.passRetained(fake) }

/// A navigation WebKit would ask about, with what the test says it is.
final class FakeNavigationAction: WKNavigationAction {
  private let fakeRequest: URLRequest
  private let fakeDownload: Bool
  private let source: WKFrameInfo

  init(url: URL?, shouldDownload: Bool = false, source: WKFrameInfo = FakeFrame()) {
    fakeRequest = url.map { URLRequest(url: $0) } ?? URLRequest(url: URL(filePath: "/"))
    fakeDownload = shouldDownload
    self.source = source
    super.init()
    keepAlive(self)
  }

  override var request: URLRequest { fakeRequest }
  override var shouldPerformDownload: Bool { fakeDownload }
  override var sourceFrame: WKFrameInfo { source }
}

/// A frame with a page URL of its own.
final class FakeFrame: WKFrameInfo {
  private let main: Bool
  private let fakeRequest: URLRequest

  init(main: Bool = true, url: URL = URL(filePath: "/")) {
    self.main = main
    fakeRequest = URLRequest(url: url)
    super.init()
    keepAlive(self)
  }

  override var isMainFrame: Bool { main }
  override var request: URLRequest { fakeRequest }
}

final class FakeNavigationResponse: WKNavigationResponse {
  private let fakeResponse: URLResponse
  private let mainFrame: Bool
  private let shows: Bool

  init(response: URLResponse, mainFrame: Bool = true, canShow: Bool = true) {
    fakeResponse = response
    self.mainFrame = mainFrame
    shows = canShow
    super.init()
    keepAlive(self)
  }

  override var response: URLResponse { fakeResponse }
  override var isForMainFrame: Bool { mainFrame }
  override var canShowMIMEType: Bool { shows }
}

// swiftlint:disable legacy_objc_type discouraged_optional_boolean
final class FakeWindowFeatures: WKWindowFeatures {
  private let size: CGSize?
  private let toolbars: Bool?

  init(size: CGSize? = nil, toolbars: Bool? = nil) {
    self.size = size
    self.toolbars = toolbars
    super.init()
    keepAlive(self)
  }

  override var width: NSNumber? { size.map { NSNumber(value: Double($0.width)) } }
  override var height: NSNumber? { size.map { NSNumber(value: Double($0.height)) } }
  override var toolbarsVisibility: NSNumber? { toolbars.map { NSNumber(value: $0) } }
}
// swiftlint:enable legacy_objc_type discouraged_optional_boolean

final class FakeOpenPanelParameters: WKOpenPanelParameters {
  private let directories: Bool
  private let multiple: Bool

  init(directories: Bool = false, multiple: Bool = false) {
    self.directories = directories
    self.multiple = multiple
    super.init()
    keepAlive(self)
  }

  override var allowsDirectories: Bool { directories }
  override var allowsMultipleSelection: Bool { multiple }
}

/// A server's protection space, with an optional trust to check.
final class FakeProtectionSpace: URLProtectionSpace, @unchecked Sendable {
  private let trust: SecTrust?

  init(host: String = "a.example", port: Int = 8443, method: String, trust: SecTrust? = nil) {
    self.trust = trust
    super.init(
      host: host, port: port, protocol: "https", realm: "realm", authenticationMethod: method)
  }

  required init?(coder: NSCoder) {
    trust = nil
    super.init(coder: coder)
  }

  override var serverTrust: SecTrust? { trust }
}

/// Answers nothing: WebKit's completion handler carries the answer.
final class SilentChallengeSender: NSObject, URLAuthenticationChallengeSender {
  func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
  func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
  func cancel(_ challenge: URLAuthenticationChallenge) {}
}

/// What a server's certificate check needs: a self-signed certificate nothing trusts.
enum UntrustedCertificate {
  private static let base64 =
    "MIIC8jCCAdqgAwIBAgIUdXkLoaQpQBw25qJYVZpPK/IJLjowDQYJKoZIhvcNAQELBQAwGDEWMBQGA1UEAwwNb21uaW"
    + "dlbnQudGVzdDAgFw0yNjExMDkwOTI0NDRaGA8yMTI2MTAxNjA5MjQ0NFowGDEWMBQGA1UEAwwNb21uaWdlbnQudGVz"
    + "dDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAIWSp1Ly9UHBNMMzjS5dzYUwRm/WzdlFSbN4aEtyYC4eVE"
    + "qUb1PcHOR7wdSCYBTKJ56kIF/+cq23IZrlx0ubgUNTYTpioWAL31UxwLmk48Zh268+NCIoZjTV1fvxPOKJcDY/ysQZ"
    + "aafZql0nJgdZOrzylJ2lEY6QKEMvvub+461fTNDb3XO6skP2hLHJfy5LBRJ4nXDfJu3S7FyAskgvPoK49ea83YfOPi"
    + "RtTLj5DysKIFjXIv4u+aWkrOPHOLNY2V0KLnotHE5DSr4FGsB5g7xx+WY2QjcZ9owwosgLkP3abLTXdDwG0H+M4djO"
    + "ib38EktnvCodU7VkP3m+D3WbHLkCAwEAAaMyMDAwHQYDVR0OBBYEFMi/tRXgimcEGpqBo2PiK+tSrXfgMA8GA1UdEw"
    + "EB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAHso0M0ccA6YTfc7F7/jTcY/PL+G/LNakPgU4zIdyTmeiE9f/diP"
    + "A1K5s9XgJ6gkuRCkSZJqtV5D6tXGuP/s0U7EQWt5BttxuDBRqmrussV/W14TR72nRkmp0A07vWPdFLw6GgPcdyvf7l"
    + "lSnHjbEGPCOFmmjzMF37pfmrcFInbmSQeMwDtPbTUP/9Ea8YNJBoty8dfrq8vUn0zriOezJOZKtpiWdSoJde12LSnr"
    + "reiasACA4fJilA9Nx0/XciqFHuUnYYmBzfc4itHrlabpSRhL1LherEK9MmloiPF9GpXGDc7gA2l6Sg/aOIq3AjassI"
    + "2TYy59phlmb3POvTAJb+8="

  static func trust() throws -> SecTrust {
    let data = try #require(Data(base64Encoded: base64))
    let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
    var trust: SecTrust?
    let status = SecTrustCreateWithCertificates(
      certificate, SecPolicyCreateBasicX509(), &trust)
    try #require(status == errSecSuccess)
    return try #require(trust)
  }
}

/// Records what a tab asks and answers it with what the test set.
@MainActor
final class SystemTabDelegate: BrowserTabDelegate {
  var requested: [BrowserPrompt] = []
  var cancelled: [BrowserPrompt] = []
  var opened: [BrowserPopup] = []
  var blocked: [BrowserBlockedPopup] = []
  var started: [BrowserDownload] = []
  var onPrompt: (BrowserPrompt) -> Void = { _ in }

  func tab(_ tab: any BrowserTab, didRequest prompt: BrowserPrompt) {
    requested.append(prompt)
    onPrompt(prompt)
  }
  func tab(_ tab: any BrowserTab, didCancel prompt: BrowserPrompt) { cancelled.append(prompt) }
  func tab(_ tab: any BrowserTab, didOpen popup: BrowserPopup) { opened.append(popup) }
  func tab(_ tab: any BrowserTab, didBlock popup: BrowserBlockedPopup) { blocked.append(popup) }
  func tab(_ tab: any BrowserTab, didStart download: BrowserDownload) { started.append(download) }
}

/// A URL policy that refuses one host.
struct RefusingPolicy: BrowserURLPolicy {
  let host: String
  var rules: BrowserURLRules { BrowserURLRules() }

  func evaluate(_ url: URL) -> BrowserURLDecision {
    url.host == host ? .deny("not here") : .allow
  }
}

/// A tab on its own ephemeral store with a recording delegate.
@MainActor
struct SystemTabFixture {
  let engine = SystemBrowserEngine()
  let delegate = SystemTabDelegate()
  let tab: SystemBrowserTab

  init() throws {
    SystemSideEffects.install()
    let made = try engine.makeTab(
      profile: .ephemeral("system-\(UUID().uuidString)"), initialURL: nil)
    tab = try #require(made as? SystemBrowserTab)
    tab.delegate = delegate
  }

  /// Loads `html` at an address no network is asked for, and waits for it.
  func load(_ html: String, base: String = "https://a.example/") async throws {
    tab.webView.loadHTMLString(html, baseURL: URL(string: base))
    let loaded = try await waitUntil { tab.webView.url != nil && !tab.webView.isLoading }
    try #require(loaded)
  }
}
