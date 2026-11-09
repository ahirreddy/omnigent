#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import Testing
  import UniformTypeIdentifiers

  @testable import OmnigentBrowser

  /// A store whose Keychain calls fail.
  final class FailingCredentialStore: BrowserCredentialStore {
    func credential(for space: BrowserProtectionSpace) throws(BrowserError) -> BrowserCredential? {
      throw .credentialStoreFailed("locked")
    }
    func save(_ credential: BrowserCredential, for space: BrowserProtectionSpace)
      throws(BrowserError)
    {
      throw .credentialStoreFailed("locked")
    }
    func removeCredential(for space: BrowserProtectionSpace) throws(BrowserError) {
      throw .credentialStoreFailed("locked")
    }
  }

  /// A presenter and a tab in a window that is never shown.
  @MainActor
  struct PresenterFixture {
    let presenter: BrowserPromptPresenter
    let tab: FakeTab
    let window: NSWindow

    init(
      profile: BrowserProfile = .server("sheets"),
      credentials: any BrowserCredentialStore = InMemoryBrowserCredentialStore()
    ) throws {
      SystemSideEffects.install()
      SystemSideEffects.reset()
      let defaults = try isolatedDefaults()
      presenter = BrowserPromptPresenter(
        permissionStore: BrowserPermissionStore(defaults: defaults),
        credentialStore: credentials,
        downloadSettings: BrowserDownloadSettings(defaults: defaults),
        downloadCenter: BrowserDownloadCenter())
      presenter.downloadSettings.askBeforeDownload = true
      tab = FakeTab(kind: .system, profile: profile, initialURL: nil)
      window = NSWindow(
        contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 300),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = tab.platformView
    }

    static let space = BrowserProtectionSpace(
      host: "site.example", port: 443, realm: "Staff", scheme: "basic", isProxy: false,
      isSecure: true)
  }

  final class Answers<Value> {
    var values: [Value] = []
  }
#endif
