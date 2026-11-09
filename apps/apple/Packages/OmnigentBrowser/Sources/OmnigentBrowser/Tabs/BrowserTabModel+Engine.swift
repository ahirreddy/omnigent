internal import Foundation
internal import os

/// The engine tab: restore, observation, history, site zoom and favicons.
extension BrowserTabModel {
  // MARK: Engine tab

  func prepare(_ tab: any BrowserTab) {
    if isMuted { tab.setAudioMuted(true) }
    lastRecordedURL = nil
    lastZoomHost = nil
    observe(tab)
    guard let state = pending else {
      restore = .done
      if let url = controller.requestedURL { tab.load(url) }
      return
    }
    if tab.engineKind == .system, let data = state.webKitInteractionState,
      tab.restoreEngineState(data)
    {
      restore = .done
      return
    }
    let history = state.effectiveHistory
    if history.entries.count <= 1 {
      restore = .done
      if let entry = history.current { tab.load(entry.url) }
      return
    }
    restore = .loadingStart(history)
    tab.load(BrowserRestorePlaceholder.startURL)
    let tabID = ObjectIdentifier(tab)
    Task { [weak self] in
      // Nothing holds this task, so nothing can cancel the wait.
      try? await Task.sleep(for: .seconds(15))
      self?.restoreTimedOut(tabID)
    }
  }

  func restoreTimedOut(_ tabID: ObjectIdentifier) {
    guard let tab, ObjectIdentifier(tab) == tabID else { return }
    switch restore {
    case .loadingStart(let history), .rebuilding(let history):
      restore = .done
      lastError = .navigationFailed(
        url: history.current?.url, code: 0,
        message: "Restoring the tab's history timed out; only the current page was loaded.")
      if let url = history.current?.url { tab.load(url) }
    case .idle, .done:
      break
    }
  }

  func observe(_ tab: any BrowserTab) {
    let tabID = ObjectIdentifier(tab)
    withObservationTracking {
      let state = tab.state
      _ = state.url
      _ = state.title
      _ = state.isLoading
      _ = state.faviconURL
      _ = state.canGoBack
      _ = state.canGoForward
      _ = state.isMuted
      _ = state.isClosed
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self, !self.isClosed, let current = self.tab, ObjectIdentifier(current) == tabID
        else {
          return
        }
        self.stateChanged(current)
        self.observe(current)
      }
    }
  }

  func stateChanged(_ tab: any BrowserTab) {
    let state = tab.state
    advanceRestore(tab)
    if state.isClosed {
      // window.close() from the page.
      environment.pageClosed(self)
      return
    }
    guard case .done = restore, let url = state.url else {
      bumpRevisionIfChanged()
      return
    }
    if BrowserRestorePlaceholder.isPlaceholder(url) {
      replacePlaceholder(url, in: tab)
      return
    }
    pending = nil
    recordHistory(url: url, title: state.title)
    applySiteZoom(url, tab: tab)
    loadFavicon(state.faviconURL, pageURL: url)
    bumpRevisionIfChanged()
  }

  func advanceRestore(_ tab: any BrowserTab) {
    switch restore {
    case .loadingStart(let history):
      guard tab.state.url == BrowserRestorePlaceholder.startURL, !tab.state.isLoading else {
        return
      }
      restore = .rebuilding(history)
      Task { [weak self] in
        do throws(BrowserError) {
          let script = BrowserRestorePlaceholder.rebuildScript(for: history)
          _ = try await tab.evaluateJavaScript(script)
        } catch {
          self?.restoreFailed(error, history: history, tab: tab)
        }
      }
    case .rebuilding:
      guard let url = tab.state.url, !BrowserRestorePlaceholder.isPlaceholder(url),
        url.absoluteString != "about:blank"
      else {
        return
      }
      restore = .done
    case .idle, .done:
      break
    }
  }

  func restoreFailed(
    _ error: BrowserError, history: BrowserNavigationHistory, tab: any BrowserTab
  ) {
    Logger.tabs.error("History restore failed: \(error.localizedDescription, privacy: .public)")
    lastError = error
    restore = .done
    if let url = history.current?.url { tab.load(url) }
  }

  /// The user went back or forward onto an entry that has not loaded since restore.
  func replacePlaceholder(_ url: URL, in tab: any BrowserTab) {
    guard !tab.state.isLoading, url != lastReplacedPlaceholder,
      BrowserRestorePlaceholder.entry(from: url) != nil
    else {
      return
    }
    lastReplacedPlaceholder = url
    Task { [weak self] in
      do throws(BrowserError) {
        _ = try await tab.evaluateJavaScript(BrowserRestorePlaceholder.replaceScript)
      } catch {
        self?.lastError = error
        if let target = BrowserRestorePlaceholder.entry(from: url)?.url { tab.load(target) }
      }
    }
  }

  func recordHistory(url: URL, title: String) {
    let history = environment.history(for: profileID)
    if url != lastRecordedURL {
      lastRecordedURL = url
      history.recordVisit(url: url, title: title, typed: nextVisitTyped)
      nextVisitTyped = false
    } else {
      history.updateTitle(title, for: url)
    }
  }

  func applySiteZoom(_ url: URL, tab: any BrowserTab) {
    let host = url.host(percentEncoded: false)?.lowercased()
    guard host != lastZoomHost else { return }
    lastZoomHost = host
    let factor = environment.zoom(for: profileID).factor(for: url)
    if abs(factor - tab.state.zoomFactor) > 0.001 { tab.setZoomFactor(factor) }
  }

  func loadFavicon(_ iconURL: URL?, pageURL: URL) {
    guard iconURL != lastFaviconURL else { return }
    lastFaviconURL = iconURL
    guard let iconURL else { return }
    Task { [weak self] in
      guard let self else { return }
      do throws(BrowserError) {
        let icon = try await self.environment.faviconLoader.favicon(at: iconURL)
        guard self.lastFaviconURL == iconURL else { return }
        self.favicon = icon
        self.bumpRevision()
      } catch {
        // A missing icon is normal; the tab keeps the generic one and says why here.
        self.faviconError = error
      }
    }
  }

  func bumpRevisionIfChanged() {
    guard let state = tab?.state else { return }
    let current =
      "\(state.url?.absoluteString ?? "")|\(state.title)|\(state.canGoBack)|\(state.canGoForward)|\(isMuted)"
    guard current != signature else { return }
    signature = current
    restoreRevision += 1
  }

  func bumpRevision() {
    restoreRevision += 1
  }
}
