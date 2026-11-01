package import Foundation

#if os(macOS)
  internal import AppKit
#else
  internal import UIKit
#endif

/// Links with schemes no engine renders (Okta Verify's `com-okta-authenticator:`, `zoommtg:`,
/// `mailto:`) leave the browser for the app that registered them, after the user confirms. Agent
/// tabs never confirm, so they never launch apps.
package enum BrowserExternalApplication {
  /// Schemes that stay in the browser, even when an engine reports them as unhandled.
  nonisolated static let browserSchemes: Set<String> = [
    "http", "https", "file", "ftp", "data", "blob", "about", "javascript", "view-source",
    "filesystem", "ws", "wss", "chrome", "chrome-extension", "devtools",
  ]

  /// Whether `url` should be handed to another app.
  nonisolated package static func isExternal(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
    return !browserSchemes.contains(scheme)
  }

  /// What the confirmation says.
  nonisolated package static func message(appName: String?, scheme: String) -> String {
    guard let appName else {
      return "This page wants to open a \(scheme): link in another app."
    }
    return "This page wants to open a \(scheme): link in \(appName)."
  }

  /// Asks through `delegate`, then opens `url`. Reports on `tab` when nothing can open it or
  /// nobody can ask.
  package static func request(
    _ url: URL, origin: URL?, from tab: any BrowserTab, delegate: (any BrowserTabDelegate)?
  ) {
    let scheme = url.scheme?.lowercased() ?? ""
    guard isExternal(url) else {
      tab.state.report(
        .featureUnsupported(feature: "Opening \(scheme): links outside", engine: tab.engineKind))
      return
    }
    #if os(macOS)
      guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
        tab.state.report(
          .featureUnsupported(feature: "No app opens \(scheme): links", engine: tab.engineKind))
        return
      }
      let bundle = Bundle(url: appURL)
      let appName: String? =
        bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? appURL.deletingPathExtension().lastPathComponent
    #else
      let appName: String? = nil
    #endif
    guard let delegate else {
      tab.state.report(
        .featureUnsupported(
          feature: "Opening \(scheme): links (no tab delegate)", engine: tab.engineKind))
      return
    }
    let holder = PromptHolder()
    let prompt = BrowserDialogPrompt(
      kind: .confirm, origin: origin, message: message(appName: appName, scheme: scheme),
      defaultText: ""
    ) { [weak tab] accepted, _ in
      guard let tab else { return }
      if let base = holder.prompt { tab.state.remove(base) }
      guard accepted else { return }
      open(url, reportingTo: tab)
    }
    holder.prompt = prompt
    let mapped = BrowserPrompt.dialog(prompt)
    tab.state.enqueue(mapped)
    delegate.tab(tab, didRequest: mapped)
  }

  private static func open(_ url: URL, reportingTo tab: any BrowserTab) {
    Task { [weak tab] in
      do {
        #if os(macOS)
          _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
        #else
          guard await UIApplication.shared.open(url) else {
            throw CocoaError(.fileReadUnsupportedScheme)
          }
        #endif
      } catch {
        tab?.state.report(
          .engineError(
            tab?.engineKind ?? .system,
            message: "Could not open \(url.scheme ?? "the"): link: \(error.localizedDescription)"))
      }
    }
  }

  /// Lets the answer closure find its own prompt.
  private final class PromptHolder {
    weak var prompt: BrowserPromptBase?
  }
}
