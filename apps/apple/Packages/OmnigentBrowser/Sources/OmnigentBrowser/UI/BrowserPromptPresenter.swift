internal import Foundation
public import Observation
internal import os

/// The app's browser UI for every engine: answers the prompts a page asks for with native
/// sheets (`BrowserPromptPresenter+AppKit.swift`, `+UIKit.swift`), remembers permission
/// decisions per profile and origin, routes downloads, shows certificate interstitials and
/// opens popups. `BrowserController` makes it the delegate of the tabs it creates.
@Observable
public final class BrowserPromptPresenter: BrowserTabDelegate {
  /// The app-wide presenter.
  public static let shared = BrowserPromptPresenter()

  /// Remembered permission decisions.
  @ObservationIgnored public let permissionStore: BrowserPermissionStore
  /// Where opted-in HTTP passwords live.
  @ObservationIgnored public let credentialStore: any BrowserCredentialStore
  /// Download folder and ask-first setting.
  public let downloadSettings: BrowserDownloadSettings
  /// The downloads list.
  public let downloadCenter: BrowserDownloadCenter
  /// Whether users may proceed past overridable certificate errors.
  public var allowsCertificateOverrides: Bool
  /// Opens a popup tab. When nil, macOS opens it in a new window.
  @ObservationIgnored public var onOpenPopup: ((BrowserPopup) -> Void)?
  /// Certificate interstitials by tab, shown by `BrowserView` over the page.
  public private(set) var interstitials: [ObjectIdentifier: BrowserCertificatePrompt] = [:]
  /// Prompts waiting for a sheet slot, per window.
  @ObservationIgnored var queue: [(tab: any BrowserTab, prompt: BrowserPrompt)] = []
  /// The prompt whose sheet is up, if any.
  @ObservationIgnored public internal(set) var presentedPrompt: BrowserPrompt?
  /// Platform objects for the presented sheet (NSAlert, panels), for dismissal and tests.
  @ObservationIgnored var presentedSheet: AnyObject?

  /// Creates a presenter.
  public init(
    permissionStore: BrowserPermissionStore = .shared,
    credentialStore: any BrowserCredentialStore = KeychainBrowserCredentialStore.shared,
    downloadSettings: BrowserDownloadSettings = BrowserDownloadSettings(),
    downloadCenter: BrowserDownloadCenter = .shared,
    allowsCertificateOverrides: Bool = true
  ) {
    self.permissionStore = permissionStore
    self.credentialStore = credentialStore
    self.downloadSettings = downloadSettings
    self.downloadCenter = downloadCenter
    self.allowsCertificateOverrides = allowsCertificateOverrides
  }

  /// The certificate interstitial to show over `tab`, if any.
  public func interstitial(for tab: any BrowserTab) -> BrowserCertificatePrompt? {
    interstitials[ObjectIdentifier(tab)]
  }

  /// Answers an interstitial.
  public func resolveInterstitial(for tab: any BrowserTab, proceed: Bool) {
    guard let prompt = interstitials.removeValue(forKey: ObjectIdentifier(tab)) else { return }
    guard proceed else {
      prompt.cancel()
      return
    }
    guard allowsCertificateOverrides else {
      prompt.cancel()
      tab.state.report(.notAllowed("Proceeding past certificate errors is turned off."))
      return
    }
    do {
      try prompt.proceed()
    } catch {
      tab.state.report(error)
    }
  }

  // MARK: BrowserTabDelegate

  /// Answers from remembered decisions or settings, or queues a native sheet.
  public func tab(_ tab: any BrowserTab, didRequest prompt: BrowserPrompt) {
    switch prompt {
    case .permission(let permission):
      if decidePermissionWithoutAsking(permission, tab: tab) { return }
    case .download(let download):
      if !downloadSettings.askBeforeDownload {
        saveWithoutAsking(download, tab: tab)
        return
      }
    case .certificateError(let certificate):
      interstitials[ObjectIdentifier(tab)] = certificate
      return
    default:
      break
    }
    queue.append((tab, prompt))
    presentNext()
  }

  /// Drops a withdrawn prompt and closes its sheet.
  public func tab(_ tab: any BrowserTab, didCancel prompt: BrowserPrompt) {
    queue.removeAll { $0.prompt.id == prompt.id }
    if case .certificateError = prompt {
      interstitials[ObjectIdentifier(tab)] = nil
    }
    if presentedPrompt?.id == prompt.id {
      dismissPresentedSheet()
    }
  }

  /// Hands the popup to `onOpenPopup`, or opens it in a window.
  public func tab(_ tab: any BrowserTab, didOpen popup: BrowserPopup) {
    popup.tab.delegate = self
    if let onOpenPopup {
      onOpenPopup(popup)
      return
    }
    openInWindow(popup)
  }

  /// Logs the block; `BrowserView` shows the tab's `lastBlockedPopup`.
  public func tab(_ tab: any BrowserTab, didBlock popup: BrowserBlockedPopup) {
    Logger.presenter.info(
      "Blocked a popup for \(popup.url?.absoluteString ?? "-", privacy: .public): \(popup.reason, privacy: .public)"
    )
  }

  /// Adds the download to the downloads list.
  public func tab(_ tab: any BrowserTab, didStart download: BrowserDownload) {
    download.profileIdentifier = tab.profile.identifier
    downloadCenter.add(download)
  }

  // MARK: Decisions without UI

  private func decidePermissionWithoutAsking(_ prompt: BrowserPermissionPrompt, tab: any BrowserTab)
    -> Bool
  {
    if prompt.permissions.contains(.other) || prompt.permissions.isEmpty {
      prompt.deny()
      return true
    }
    switch permissionStore.decision(
      for: prompt.permissions, origin: prompt.origin, profile: tab.profile)
    {
    case .allow:
      prompt.allow()
      return true
    case .deny:
      prompt.deny()
      return true
    case nil:
      return false
    }
  }

  private func saveWithoutAsking(_ prompt: BrowserDownloadPrompt, tab: any BrowserTab) {
    do {
      try FileManager.default.createDirectory(
        at: downloadSettings.directory, withIntermediateDirectories: true)
    } catch {
      prompt.cancel()
      tab.state.report(
        .downloadFailed("The download folder is unavailable: \(error.localizedDescription)"))
      return
    }
    prompt.save(to: downloadSettings.uniqueDestination(for: prompt.suggestedName))
  }

  /// Records the answer to a permission sheet.
  func recordPermission(
    _ prompt: BrowserPermissionPrompt, allowed: Bool, remember: Bool, tab: any BrowserTab
  ) {
    if remember {
      permissionStore.record(
        allowed ? .allow : .deny, for: prompt.permissions, origin: prompt.origin,
        profile: tab.profile)
    }
    if allowed {
      prompt.allow()
    } else {
      prompt.deny()
    }
  }

  /// Saves opted-in credentials; never for ephemeral profiles.
  func rememberCredential(
    _ credential: BrowserCredential, for prompt: BrowserAuthPrompt, tab: any BrowserTab
  ) {
    guard tab.profile.persistence == .persistent else { return }
    do {
      try credentialStore.save(credential, for: prompt.space)
    } catch {
      tab.state.report(error)
    }
  }

  /// A stored credential to prefill, reporting Keychain errors on the tab.
  func storedCredential(for prompt: BrowserAuthPrompt, tab: any BrowserTab) -> BrowserCredential? {
    guard tab.profile.persistence == .persistent else { return nil }
    do {
      return try credentialStore.credential(for: prompt.space)
    } catch {
      tab.state.report(error)
      return nil
    }
  }

  /// Called when a sheet closes; shows the next queued prompt.
  func sheetDidEnd() {
    presentedPrompt = nil
    presentedSheet = nil
    presentNext()
  }

  private func presentNext() {
    guard presentedPrompt == nil else { return }
    while !queue.isEmpty {
      let (tab, prompt) = queue.removeFirst()
      guard !prompt.base.isFinished else { continue }
      presentedPrompt = prompt
      if showSheet(prompt, for: tab) {
        return
      }
      presentedPrompt = nil
    }
  }

  /// Denies a prompt that cannot be shown and says why.
  func denyUnshowable(_ prompt: BrowserPrompt, tab: any BrowserTab, reason: String) {
    switch prompt {
    case .dialog(let dialog): dialog.cancel()
    case .permission(let permission): permission.deny()
    case .fileChooser(let chooser): chooser.cancel()
    case .download(let download): download.cancel()
    case .authentication(let auth): auth.cancel()
    case .certificateError(let certificate): certificate.cancel()
    case .color(let color): color.cancel()
    }
    tab.state.report(
      .featureUnsupported(feature: "\(prompt.kindName): \(reason)", engine: tab.engineKind))
  }
}

extension Logger {
  static let presenter = Logger(subsystem: "ai.omnigent.browser", category: "presenter")
}
