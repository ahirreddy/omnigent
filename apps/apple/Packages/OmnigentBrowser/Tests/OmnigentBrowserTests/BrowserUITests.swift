import Foundation
import Testing

@testable import OmnigentBrowser

@MainActor
private func freshDefaults() throws -> UserDefaults {
  let name = "ai.omnigent.browser.tests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: name))
  defaults.removePersistentDomain(forName: name)
  return defaults
}

private func removeTestFolder(_ folder: URL) {
  do {
    if FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.removeItem(at: folder)
    }
  } catch {
    Issue.record("Could not remove \(folder.path): \(error)")
  }
}

@MainActor
@Suite("Permission store")
struct PermissionStoreTests {
  @Test func persistentProfilesPersistAndEphemeralOnesStayInMemory() throws {
    let defaults = try freshDefaults()
    let store = BrowserPermissionStore(defaults: defaults)
    let server = BrowserProfile.server("s1")
    let agent = BrowserProfile.ephemeral("agent:1")
    store.record(.deny, for: [.camera, .microphone], origin: "https://a.test", profile: server)
    store.record(.allow, for: .notifications, origin: "https://a.test", profile: agent)
    #expect(store.decision(for: .camera, origin: "https://a.test", profile: server) == .deny)
    #expect(
      store.decision(for: [.camera, .geolocation], origin: "https://a.test", profile: server)
        == .deny)
    #expect(store.decision(for: .geolocation, origin: "https://a.test", profile: server) == nil)
    #expect(store.decision(for: .camera, origin: "https://b.test", profile: server) == nil)
    #expect(store.decision(for: .notifications, origin: "https://a.test", profile: agent) == .allow)
    // A new store over the same defaults sees the persistent decisions only.
    let reopened = BrowserPermissionStore(defaults: defaults)
    #expect(reopened.decision(for: .camera, origin: "https://a.test", profile: server) == .deny)
    #expect(reopened.decision(for: .notifications, origin: "https://a.test", profile: agent) == nil)
    #expect(
      defaults.dictionary(forKey: BrowserPermissionStore.defaultsKeyPrefix + agent.storageKey)
        == nil)
    reopened.reset(profile: server)
    #expect(reopened.decisions(for: server).isEmpty)
  }

  @Test func originsAreSchemeHostAndPort() {
    #expect(
      BrowserPermissionStore.origin(of: URL(string: "HTTPS://Meet.Example:8443/x?y"))
        == "https://meet.example:8443")
    #expect(
      BrowserPermissionStore.origin(of: URL(string: "http://127.0.0.1/page")) == "http://127.0.0.1")
    #expect(BrowserPermissionStore.origin(of: nil).isEmpty)
  }
}

@MainActor
@Suite("Download settings")
struct DownloadSettingsTests {
  @Test func destinationsAreSafeAndUnique() throws {
    let defaults = try freshDefaults()
    let settings = BrowserDownloadSettings(defaults: defaults)
    #expect(settings.directory == URL.downloadsDirectory)
    #expect(!settings.askBeforeDownload)
    let folder = FileManager.default.temporaryDirectory.appending(path: "owl-dl-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { removeTestFolder(folder) }
    settings.directory = folder
    settings.askBeforeDownload = true
    let reread = BrowserDownloadSettings(defaults: defaults)
    #expect(reread.directory.path == folder.path && reread.askBeforeDownload)
    #expect(BrowserDownloadSettings.safeFileName("../../etc/passwd") == "passwd")
    #expect(BrowserDownloadSettings.safeFileName(".hidden") == "hidden")
    #expect(BrowserDownloadSettings.safeFileName("") == "download")
    let first = settings.uniqueDestination(for: "report.pdf")
    try Data().write(to: first)
    #expect(settings.uniqueDestination(for: "report.pdf").lastPathComponent == "report 2.pdf")
  }
}

@MainActor
@Suite("Prompt presenter")
struct PromptPresenterTests {
  private func presenter(_ defaults: UserDefaults, credentials: InMemoryBrowserCredentialStore)
    -> BrowserPromptPresenter
  {
    BrowserPromptPresenter(
      permissionStore: BrowserPermissionStore(defaults: defaults), credentialStore: credentials,
      downloadSettings: BrowserDownloadSettings(defaults: defaults),
      downloadCenter: BrowserDownloadCenter())
  }

  @Test func rememberedPermissionsAreAnsweredWithoutUI() throws {
    let defaults = try freshDefaults()
    let presenter = presenter(defaults, credentials: InMemoryBrowserCredentialStore())
    let tab = FakeTab(kind: .system, profile: .server("s"), initialURL: nil)
    presenter.permissionStore.record(
      .allow, for: .camera, origin: "https://a.test", profile: tab.profile)
    var answer: BrowserPermissionAnswer?
    let prompt = BrowserPermissionPrompt(origin: "https://a.test", permissions: .camera) {
      answer = $0
    }
    presenter.tab(tab, didRequest: .permission(prompt))
    #expect(answer == .allow && prompt.isFinished)
    var other: BrowserPermissionAnswer?
    let unknown = BrowserPermissionPrompt(origin: "https://a.test", permissions: .other) {
      other = $0
    }
    presenter.tab(tab, didRequest: .permission(unknown))
    #expect(other == .deny)
  }

  @Test func downloadsGoStraightToTheFolderUnlessAsked() throws {
    let defaults = try freshDefaults()
    let presenter = presenter(defaults, credentials: InMemoryBrowserCredentialStore())
    let folder = FileManager.default.temporaryDirectory.appending(path: "owl-dl-\(UUID())")
    presenter.downloadSettings.directory = folder
    defer { removeTestFolder(folder) }
    var destination: URL?
    let prompt = BrowserDownloadPrompt(
      url: URL(string: "https://x.test/a.zip"), suggestedName: "a.zip", mimeType: "",
      totalBytes: nil
    ) { destination = $0 }
    let tab = FakeTab(kind: .system, profile: .server("s"), initialURL: nil)
    presenter.tab(tab, didRequest: .download(prompt))
    #expect(destination == folder.appending(path: "a.zip"))
    #expect(FileManager.default.fileExists(atPath: folder.path))
  }

  @Test func certificateOverridesFollowThePolicy() throws {
    let defaults = try freshDefaults()
    let presenter = presenter(defaults, credentials: InMemoryBrowserCredentialStore())
    let tab = FakeTab(kind: .chromium, profile: .server("s"), initialURL: nil)
    var proceeded = true
    let prompt = BrowserCertificatePrompt(
      url: URL(string: "https://bad.test"), message: "untrusted", errorCode: -202, subject: "",
      issuer: "", isOverridable: true
    ) { proceeded = $0 }
    presenter.tab(tab, didRequest: .certificateError(prompt))
    #expect(presenter.interstitial(for: tab) === prompt)
    presenter.allowsCertificateOverrides = false
    presenter.resolveInterstitial(for: tab, proceed: true)
    #expect(proceeded == false)
    #expect(tab.state.lastError == .notAllowed("Proceeding past certificate errors is turned off."))
    #expect(presenter.interstitial(for: tab) == nil)
  }

  @Test func credentialsAreOnlyStoredOnOptInForPersistentProfiles() throws {
    let defaults = try freshDefaults()
    let credentials = InMemoryBrowserCredentialStore()
    let presenter = presenter(defaults, credentials: credentials)
    let space = BrowserProtectionSpace(
      host: "h", port: 80, realm: "r", scheme: "basic", isProxy: false, isSecure: false)
    let prompt = BrowserAuthPrompt(space: space) { _ in }
    let credential = BrowserCredential(username: "u", password: "p")
    presenter.rememberCredential(
      credential, for: prompt,
      tab: FakeTab(kind: .system, profile: .ephemeral("e"), initialURL: nil))
    #expect(credentials.credential(for: space) == nil)
    presenter.rememberCredential(
      credential, for: prompt, tab: FakeTab(kind: .system, profile: .server("s"), initialURL: nil))
    #expect(credentials.credential(for: space) == credential)
  }

  @Test func promptsAnswerOnce() {
    var answers = 0
    let dialog = BrowserDialogPrompt(
      kind: .confirm, origin: nil, message: "", defaultText: ""
    ) { _, _ in answers += 1 }
    dialog.accept()
    dialog.cancel()
    #expect(answers == 1)
    let withdrawn = BrowserColorPrompt(initialColor: "#000000") { _ in answers += 1 }
    withdrawn.withdraw(reason: "navigated")
    withdrawn.choose("#ffffff")
    #expect(answers == 1 && withdrawn.cancellationReason == "navigated")
  }
}

@MainActor
@Suite("Keychain credential store")
struct KeychainCredentialStoreTests {
  @Test func roundTripsInTheLoginKeychain() throws {
    let store = KeychainBrowserCredentialStore(itemDescription: "Omnigent Browser Test \(UUID())")
    let space = BrowserProtectionSpace(
      host: "owl-test.invalid", port: 8443, realm: "Tests", scheme: "basic", isProxy: false,
      isSecure: true)
    defer {
      do {
        try store.removeCredential(for: space)
      } catch {
        Issue.record("cleanup failed: \(error)")
      }
    }
    #expect(try store.credential(for: space) == nil)
    try store.save(BrowserCredential(username: "owl", password: "secret"), for: space)
    #expect(
      try store.credential(for: space) == BrowserCredential(username: "owl", password: "secret"))
    try store.save(BrowserCredential(username: "owl", password: "changed"), for: space)
    #expect(try store.credential(for: space)?.password == "changed")
  }
}
