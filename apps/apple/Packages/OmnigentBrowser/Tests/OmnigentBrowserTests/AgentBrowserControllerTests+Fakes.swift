import Foundation
import Testing

@testable import OmnigentBrowser

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Records agent input and lets a test react to it (for example by opening a dialog).
@MainActor
final class RecordingAgentInput: BrowserAgentInput {
  var isRendererDirect: Bool { true }
  var needsHostWindow: Bool { false }
  private(set) var preparedViewport: CGSize?

  func prepareForAgent(viewport: CGSize) {
    preparedViewport = viewport
  }
  private(set) var clicks: [CGPoint] = []
  private(set) var inserted: [String] = []
  private(set) var presses: [(BrowserAgentKey, BrowserAgentModifiers)] = []
  struct Scroll: Equatable {
    let point: CGPoint
    let deltaX: Double
    let deltaY: Double
  }

  private(set) var scrolls: [Scroll] = []
  var onClick: (() -> Void)?

  func click(at point: CGPoint, clickCount: Int) throws(BrowserError) {
    clicks.append(point)
    onClick?()
  }

  func scroll(at point: CGPoint, deltaX: Double, deltaY: Double) throws(BrowserError) {
    scrolls.append(Scroll(point: point, deltaX: deltaX, deltaY: deltaY))
  }

  func insertText(_ text: String) throws(BrowserError) {
    inserted.append(text)
  }

  func press(_ key: BrowserAgentKey, modifiers: BrowserAgentModifiers) throws(BrowserError) {
    presses.append((key, modifiers))
  }
}

/// A tab whose scripts are answered by `respond`, picked by what each script does.
@MainActor
final class AgentFakeTab: BrowserTab {
  let engineKind = BrowserEngineKind.chromium
  let profile: BrowserProfile
  let state = BrowserTabState()
  let platformView = BrowserPlatformView(frame: .zero)
  weak var delegate: (any BrowserTabDelegate)?
  var popupPolicy = BrowserPopupPolicy.allow
  var urlPolicy: (any BrowserURLPolicy)?
  let recorder = RecordingAgentInput()
  var agentInput: any BrowserAgentInput { recorder }
  private(set) var loads: [URL] = []
  private(set) var policyAtLoad: [BrowserURLRules?] = []
  private(set) var scripts: [String] = []
  var title = "Agent page"
  var snapshotPNG = Data([0x89, 0x50, 0x4E, 0x47])
  /// Makes the next document-state probe find the engine still creating the page.
  var pageNotReady = false
  /// Answers scripts other than the document-state probe.
  var respond: (String) throws(BrowserError) -> BrowserScriptValue = { _ in .undefined }

  init(profile: BrowserProfile) {
    self.profile = profile
  }

  func load(_ url: URL) {
    loads.append(url)
    policyAtLoad.append(urlPolicy?.rules)
    state.url = url
    state.isLoading = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
      MainActor.assumeIsolated { self.state.isLoading = false }
    }
  }

  func goBack() {}
  func goForward() {}
  func reload() {}
  func stopLoading() {}

  func evaluateJavaScript(_ script: String) throws(BrowserError) -> BrowserScriptValue {
    scripts.append(script)
    if script.contains("document.readyState") {
      if pageNotReady {
        pageNotReady = false
        throw .tabNotReady
      }
      return .string(
        #"{"href":"\#(state.url?.absoluteString ?? "about:blank")","readyState":"complete","title":"\#(title)"}"#
      )
    }
    return try respond(script)
  }

  func takeSnapshotPNG() throws(BrowserError) -> Data { snapshotPNG }

  func find(_ text: String, forward: Bool, caseSensitive: Bool) throws(BrowserError)
    -> BrowserFindResult
  {
    BrowserFindResult(matchFound: false, matchCount: nil, activeMatch: nil)
  }

  func showDevTools() throws(BrowserError) {}
  func close() { state.isClosed = true }
  func reload(ignoringCache: Bool) {}
  func stopFinding() {}
  func setZoomFactor(_ factor: Double) {}
  func setAudioMuted(_ muted: Bool) {}
  var navigationHistory: BrowserNavigationHistory { .empty }
  var engineRestoreData: Data? { nil }
  func restoreEngineState(_ data: Data) -> Bool { false }
  func printPage() throws(BrowserError) {}
  func viewSourceURL() throws(BrowserError) -> URL { throw .tabNotReady }
}

@MainActor
final class AgentFakeEngine: BrowserEngine, BrowserEngineProvider {
  let kind = BrowserEngineKind.chromium
  private(set) var tabs: [AgentFakeTab] = []
  var configure: (AgentFakeTab) -> Void = { _ in }

  var offeredEngines: [BrowserEngineKind] { [.chromium] }
  func availability(of kind: BrowserEngineKind) -> BrowserEngineAvailability { .available }
  func engine(for kind: BrowserEngineKind) throws(BrowserError) -> any BrowserEngine { self }

  func makeTab(profile: BrowserProfile, initialURL: URL?) throws(BrowserError) -> any BrowserTab {
    let tab = AgentFakeTab(profile: profile)
    configure(tab)
    tabs.append(tab)
    return tab
  }

  func removeData(
    _ types: BrowserDataTypes, for profile: BrowserProfile, since: Date?, origins: [URL]
  ) throws(BrowserError) {}

  func deleteProfileData(_ profile: BrowserProfile) throws(BrowserError) {}
}
