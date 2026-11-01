internal import AppKit
internal import Foundation
internal import OmnigentBrowser
internal import OmnigentBrowserChromium
internal import OmnigentWebLayer
internal import SwiftUI

/// Offers both engines to the shared browser UI; Chromium reuses the example's session, so the
/// proofs drive one web host.
final class HarnessProvider: BrowserEngineProvider {
  private let session: Session
  private var chromium: ChromiumBrowserEngine?
  private let system = SystemBrowserEngine()

  init(session: Session) {
    self.session = session
  }

  var offeredEngines: [BrowserEngineKind] { [.chromium, .system] }

  func availability(of kind: BrowserEngineKind) -> BrowserEngineAvailability { .available }

  func engine(for kind: BrowserEngineKind) throws(BrowserError) -> any BrowserEngine {
    if kind == .system { return system }
    if let chromium { return chromium }
    let engine = ChromiumBrowserEngine.attach(to: session)
    chromium = engine
    return engine
  }
}

/// A window running the app's shared browser UI (`BrowserView` plus `BrowserPromptPresenter`)
/// for one engine, with private stores so proofs never touch real settings or the Keychain.
final class BrowserHarness {
  let kind: BrowserEngineKind
  let presenter: BrowserPromptPresenter
  let controller: BrowserController
  let window: NSWindow
  let defaults: UserDefaults
  let credentials = InMemoryBrowserCredentialStore()
  let downloads = BrowserDownloadCenter()
  let downloadDirectory: URL
  private let suiteName = "ai.omnigent.weblayer-example.proof.\(UUID().uuidString)"

  init(kind: BrowserEngineKind, provider: HarnessProvider, profile: BrowserProfile, url: URL?)
    throws
  {
    self.kind = kind
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      throw ProofFailure("Cannot create a defaults suite for the proof.")
    }
    self.defaults = defaults
    downloadDirectory = FileManager.default.temporaryDirectory
      .appending(path: "owl2-downloads-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: downloadDirectory, withIntermediateDirectories: true)
    let settings = BrowserDownloadSettings(defaults: defaults)
    settings.directory = downloadDirectory
    presenter = BrowserPromptPresenter(
      permissionStore: BrowserPermissionStore(defaults: defaults), credentialStore: credentials,
      downloadSettings: settings, downloadCenter: downloads)
    controller = BrowserController(
      profile: profile, preferences: BrowserPreferences(defaults: defaults, defaultEngine: kind),
      provider: provider, initialURL: url, presenter: presenter)
    window = NSWindow(
      contentRect: NSRect(x: 80, y: 80, width: 1000, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Shared browser UI (\(kind.displayName))"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: BrowserView(controller: controller))
    window.level = .floating
    window.makeKeyAndOrderFront(nil)
    controller.activate()
  }

  var tab: (any BrowserTab)? { controller.tab }

  func requireTab() throws -> any BrowserTab {
    guard let tab else { throw ProofFailure("The harness has no tab: \(controller.content)") }
    return tab
  }

  func close() {
    controller.close()
    window.close()
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    do {
      try FileManager.default.removeItem(at: downloadDirectory)
    } catch {
      Clock.log("could not remove \(downloadDirectory.path): \(error.localizedDescription)")
    }
  }
}
