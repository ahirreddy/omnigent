public import Foundation
internal import WebKit
internal import os

#if os(macOS)
  internal import AppKit
#else
  internal import UIKit
#endif

/// Browsing state on WebKit: favicons and audible state from a content-world bridge script,
/// mute, zoom, hard reload, history and `interactionState` restore, print and source.
extension SystemBrowserTab {
  func reload(ignoringCache: Bool) {
    guard !state.isClosed else { return }
    if ignoringCache {
      webView.reloadFromOrigin()
    } else {
      webView.reload()
    }
  }

  func stopFinding() {
    guard !state.isClosed else { return }
    // WKWebView selects the match; clearing the selection removes the highlight.
    let done: @MainActor (Result<Any, any Error>) -> Void = { [weak self] result in
      if case .failure(let error) = result {
        self?.state.report(.findFailed(error.localizedDescription))
      }
    }
    webView.evaluateJavaScript(
      "window.getSelection()?.removeAllRanges(); true", in: nil, in: .page,
      completionHandler: done)
  }

  func setZoomFactor(_ factor: Double) {
    guard !state.isClosed else { return }
    webView.pageZoom = factor
    state.zoomFactor = factor
  }

  func setAudioMuted(_ muted: Bool) {
    guard !state.isClosed else { return }
    state.isMuted = muted
    for frame in bridgeFrames.values {
      applyMute(in: frame)
    }
  }

  func applyMute(in frame: WKFrameInfo?) {
    let script = "globalThis.__omnigentBrowser?.setMuted(\(state.isMuted)) ?? false"
    let done: @MainActor (Result<Any, any Error>) -> Void = { [weak self] result in
      guard case .failure(let error) = result else { return }
      // A frame that went away since it said hello has nothing left to mute.
      if (error as NSError).code == WKError.Code.javaScriptInvalidFrameTarget.rawValue { return }
      self?.state.report(.scriptFailed(message: "Muting failed: \(error.localizedDescription)"))
    }
    webView.evaluateJavaScript(
      script, in: frame, in: SystemPageBridge.world, completionHandler: done)
  }

  var navigationHistory: BrowserNavigationHistory {
    let list = webView.backForwardList
    var items = list.backList
    if let current = list.currentItem { items.append(current) }
    let index = items.count - 1
    items += list.forwardList
    return BrowserNavigationHistory(
      entries: items.map { BrowserNavigationEntry(url: $0.url, title: $0.title ?? "") },
      currentIndex: max(0, index))
  }

  var engineRestoreData: Data? {
    webView.interactionState as? Data
  }

  func restoreEngineState(_ data: Data) -> Bool {
    guard !state.isClosed else { return false }
    webView.interactionState = data
    return webView.backForwardList.currentItem != nil
  }

  func printPage() throws(BrowserError) {
    guard !state.isClosed else { throw .tabClosed }
    #if os(macOS)
      guard let window = webView.window else {
        throw .printFailed("The page is not in a window.")
      }
      // coverage:off the print sheet; VM flow backlog "print a browser page"
      let operation = webView.printOperation(with: NSPrintInfo.shared)
      operation.view?.frame = webView.bounds
      operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    #else
      let controller = UIPrintInteractionController.shared
      controller.printFormatter = webView.viewPrintFormatter()
      controller.present(animated: true)
    #endif
  }
  // coverage:on

  func viewSourceURL() async throws(BrowserError) -> URL {
    let value = try await evaluateJavaScript("document.documentElement.outerHTML")
    guard let html = value.stringValue else {
      throw .scriptFailed(message: "The page has no source to show.")
    }
    let doctype = "<!DOCTYPE html>\n"
    let encoded = Data((doctype + html).utf8).base64EncodedString()
    let address = "data:text/plain;charset=utf-8;base64,\(encoded)"
    guard let url = URL(string: address) else { throw .invalidURL("view-source") }
    return url
  }

  /// A message from the bridge script in one frame.
  func bridgeMessage(_ body: [String: Any], frame: WKFrameInfo) {
    guard let type = body["type"] as? String, let frameID = body["frame"] as? String else {
      Logger.systemEngine.error("Bridge message without a type or frame.")
      return
    }
    switch type {
    case "ready":
      bridgeFrames[frameID] = frame
      if state.isMuted { applyMute(in: frame) }
    case "audio":
      audibleFrames[frameID] = body["audible"] as? Bool ?? false
      state.isAudible = audibleFrames.values.contains(true)
    case "gone":
      bridgeFrames[frameID] = nil
      audibleFrames[frameID] = nil
      state.isAudible = audibleFrames.values.contains(true)
    case "favicon":
      guard frame.isMainFrame else { return }
      state.faviconURL = (body["url"] as? String).flatMap(URL.init(string:))
    default:
      Logger.systemEngine.error("Unknown bridge message \(type, privacy: .public).")
    }
  }

  /// A new main-frame document: frames and their state start over.
  func mainFrameCommitted() {
    bridgeFrames.removeAll()
    audibleFrames.removeAll()
    state.isAudible = false
    state.faviconURL = nil
  }
}

/// Routes bridge messages to the tab whose web view sent them. One instance serves every
/// content controller, which keeps it alive; tabs are held weakly.
final class SystemPageBridge: NSObject, WKScriptMessageHandler {
  static let shared = SystemPageBridge()
  static let world = WKContentWorld.world(name: "omnigent-browser")
  static let handlerName = "omnigentBrowser"

  private let tabs = NSMapTable<WKWebView, SystemBrowserTab>.weakToWeakObjects()
  private let installed = NSHashTable<WKUserContentController>.weakObjects()

  /// Adds the script and handler to `controller` once. Popups share their opener's controller.
  func install(in controller: WKUserContentController) {
    guard !installed.contains(controller) else { return }
    installed.add(controller)
    controller.addUserScript(
      WKUserScript(
        source: Self.source, injectionTime: .atDocumentStart, forMainFrameOnly: false,
        in: Self.world))
    controller.add(self, contentWorld: Self.world, name: Self.handlerName)
  }

  func register(_ tab: SystemBrowserTab) {
    tabs.setObject(tab, forKey: tab.webView)
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard let webView = message.webView, let tab = tabs.object(forKey: webView) else { return }
    guard let body = message.body as? [String: Any] else {
      Logger.systemEngine.error("Bridge message body is not an object.")
      return
    }
    tab.bridgeMessage(body, frame: message.frameInfo)
  }

  /// Reports the page icon (main frame) and whether media plays with sound, and mutes media on
  /// request. Media the browser muted counts as audible, so the tab still shows a muted speaker.
  static let source = """
    (() => {
      if (globalThis.__omnigentBrowser) return;
      const frame = crypto.randomUUID();
      const post = (message) =>
        window.webkit.messageHandlers.\(handlerName).postMessage({ ...message, frame });
      let muted = false;
      const mutedByBrowser = new WeakSet();
      const seen = new WeakSet();
      let tracked = [];
      let lastAudible = null;
      const media = () => {
        tracked = tracked.filter((ref) => ref.deref() !== undefined);
        const all = new Set(document.querySelectorAll('audio, video'));
        for (const ref of tracked) all.add(ref.deref());
        return [...all].filter(Boolean);
      };
      const applyMute = (element) => {
        if (muted && !element.muted) { mutedByBrowser.add(element); element.muted = true; }
        if (!muted && mutedByBrowser.has(element)) { mutedByBrowser.delete(element); element.muted = false; }
      };
      const audible = (element) => !element.paused && !element.ended && element.volume > 0 &&
        element.readyState >= 2 && (!element.muted || mutedByBrowser.has(element));
      const reportAudio = () => {
        const now = media().some(audible);
        if (now !== lastAudible) { lastAudible = now; post({ type: 'audio', audible: now }); }
      };
      for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied',
        'loadeddata']) {
        document.addEventListener(type, (event) => {
          const target = event.target;
          if (target instanceof HTMLMediaElement) {
            if (!seen.has(target)) { seen.add(target); tracked.push(new WeakRef(target)); }
            applyMute(target);
          }
          reportAudio();
        }, true);
      }
      let lastIcon = null;
      const reportIcon = () => {
        if (window !== window.top || !/^https?:$/.test(location.protocol)) return;
        const links = [...document.querySelectorAll('link[rel][href]')].filter((link) =>
          /(^|\\s)(icon|apple-touch-icon)(\\s|$)/i.test(link.rel));
        const score = (link) => {
          const size = parseInt((link.sizes?.value || '').split('x')[0], 10) || 16;
          const touch = /apple-touch-icon/i.test(link.rel) ? 1000 : 0;
          return touch + Math.abs(size - 32);
        };
        links.sort((a, b) => score(a) - score(b));
        const href = links[0]?.href || new URL('/favicon.ico', location.href).href;
        if (href !== lastIcon) { lastIcon = href; post({ type: 'favicon', url: href }); }
      };
      globalThis.__omnigentBrowser = {
        setMuted(value) { muted = value; media().forEach(applyMute); reportAudio(); return true; },
      };
      post({ type: 'ready' });
      addEventListener('pagehide', () => post({ type: 'gone' }));
      const watchHead = () => {
        reportIcon();
        new MutationObserver(reportIcon).observe(document.head || document.documentElement,
          { childList: true, subtree: true, attributes: true, attributeFilter: ['href', 'rel'] });
      };
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', watchHead, { once: true });
      } else {
        watchHead();
      }
    })();
    """
}

extension Logger {
  static let systemEngine = Logger(subsystem: "ai.omnigent.browser", category: "webkit")
}

/// Profile data on WebKit: one `WKWebsiteDataStore` per persistent profile.
extension SystemBrowserEngine {
  /// See `BrowserEngine.removeData(_:for:since:origins:)`. WebKit clears every site.
  public func removeData(
    _ types: BrowserDataTypes, for profile: BrowserProfile, since: Date?, origins: [URL]
  ) async throws(BrowserError) {
    var kinds: Set<String> = []
    let all = WKWebsiteDataStore.allWebsiteDataTypes()
    if types.contains(.cookies) { kinds.insert(WKWebsiteDataTypeCookies) }
    let caches: Set<String> = [
      WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
    ]
    if types.contains(.cache) { kinds.formUnion(caches) }
    if types.contains(.siteData) {
      kinds.formUnion(all.subtracting(caches).subtracting([WKWebsiteDataTypeCookies]))
    }
    guard !kinds.isEmpty else { return }
    await dataStore(for: profile).removeData(ofTypes: kinds, modifiedSince: since ?? .distantPast)
  }

  /// See `BrowserEngine.deleteProfileData(_:)`.
  public func deleteProfileData(_ profile: BrowserProfile) async throws(BrowserError) {
    try await removeData(.engineData, for: profile, since: nil, origins: [])
    switch profile.persistence {
    case .ephemeral:
      forgetEphemeralStore(profile)
    case .persistent:
      await Self.removeStore(profile.dataStoreIdentifier)
    }
  }

  /// The network process lets go of a store shortly after its last web view; the data is already
  /// cleared, so a store still in use is removed at the next launch instead.
  static func removeStore(
    _ identifier: UUID, remove: StoreRemoval = WKWebsiteDataStore.remove(forIdentifier:),
    retryDelay: Duration = .milliseconds(300), defaults: UserDefaults = .standard
  ) async {
    for attempt in 0..<5 {
      do {
        try await remove(identifier)
        return
      } catch {
        Logger.systemEngine.info(
          "Data store busy (\(attempt)): \(error.localizedDescription, privacy: .public)")
      }
      do {
        try await Task.sleep(for: retryDelay * (attempt + 1))
      } catch {
        break
      }
    }
    queueStoreRemoval(identifier, defaults: defaults)
  }

  /// Removes a persistent profile's WebKit data store, or says why it couldn't.
  typealias StoreRemoval = @MainActor (UUID) async throws -> Void

  static let pendingRemovalKey = "ai.omnigent.browser.webkit.pendingStoreRemovals"

  static func queueStoreRemoval(_ identifier: UUID, defaults: UserDefaults = .standard) {
    var pending = defaults.stringArray(forKey: pendingRemovalKey) ?? []
    if !pending.contains(identifier.uuidString) { pending.append(identifier.uuidString) }
    defaults.set(pending, forKey: pendingRemovalKey)
  }

  /// Removes data stores of profiles deleted while their store was in use. Called before any
  /// tab exists.
  static func removeQueuedStores(
    remove: StoreRemoval = WKWebsiteDataStore.remove(forIdentifier:),
    defaults: UserDefaults = .standard
  ) async {
    let pending = defaults.stringArray(forKey: pendingRemovalKey) ?? []
    guard !pending.isEmpty else { return }
    var remaining: [String] = []
    for raw in pending {
      guard let identifier = UUID(uuidString: raw) else { continue }
      do {
        try await remove(identifier)
      } catch {
        Logger.systemEngine.error(
          "Removing the deleted profile's store \(raw, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
        )
        remaining.append(raw)
      }
    }
    defaults.set(remaining, forKey: pendingRemovalKey)
  }
}
