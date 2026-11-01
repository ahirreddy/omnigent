public import Foundation

/// Commands for the toolbar, menus and keyboard shortcuts.
extension BrowserTabModel {
  // MARK: Commands

  /// Loads `url`.
  public func load(_ url: URL, typed: Bool = false) {
    guard !isClosed else { return }
    nextVisitTyped = typed
    pending = nil
    if tab != nil { restore = .done }
    controller.load(url)
    bumpRevision()
  }

  /// Loads what the omnibox holds: a URL, or a search with the chosen engine.
  /// - Throws: `.invalidURL` for empty text.
  public func submitOmnibox(_ text: String) throws(BrowserError) {
    guard
      let input = BrowserOmnibox.interpret(text, searchEngine: environment.settings.searchEngine)
    else {
      throw .invalidURL(text)
    }
    load(input.url, typed: true)
  }

  /// Asks the content view to focus the omnibox.
  public func focusOmnibox() { omniboxFocusRequest += 1 }

  /// Goes back.
  public func goBack() { tab?.goBack() }
  /// Goes forward.
  public func goForward() { tab?.goForward() }
  /// Reloads.
  public func reload() { tab?.reload(ignoringCache: false) }
  /// Reloads, revalidating every resource.
  public func reloadIgnoringCache() { tab?.reload(ignoringCache: true) }
  /// Stops loading.
  public func stopLoading() { tab?.stopLoading() }

  /// Mutes or unmutes the tab.
  public func toggleMute() {
    isMuted.toggle()
    tab?.setAudioMuted(isMuted)
    bumpRevision()
  }

  /// One zoom step in.
  public func zoomIn() { setZoom(BrowserZoomStore.step(from: zoomFactor, upward: true)) }
  /// One zoom step out.
  public func zoomOut() { setZoom(BrowserZoomStore.step(from: zoomFactor, upward: false)) }
  /// Back to 100%.
  public func resetZoom() { setZoom(1) }

  /// Sets the zoom and remembers it for the site.
  public func setZoom(_ factor: Double) {
    tab?.setZoomFactor(factor)
    environment.zoom(for: profileID).setFactor(factor, for: url)
  }

  /// Shows the find bar and focuses it.
  public func showFindBar() {
    find.isVisible = true
    find.focusRequest += 1
  }

  /// Highlights the next (or previous) match of `find.query`.
  public func findNext(forward: Bool = true) async {
    guard let tab, !find.query.isEmpty else {
      find.result = nil
      return
    }
    do {
      find.result = try await tab.find(
        find.query, forward: forward, caseSensitive: find.caseSensitive)
    } catch {
      lastError = error
    }
  }

  /// Hides the find bar and clears highlights.
  public func hideFindBar() {
    find.isVisible = false
    find.result = nil
    tab?.stopFinding()
  }

  /// Opens the engine's web inspector.
  public func showDevTools() {
    guard let tab else { return }
    do {
      try tab.showDevTools()
    } catch {
      lastError = error
    }
  }

  /// Shows the print panel.
  public func printPage() {
    guard let tab else { return }
    Task {
      do throws(BrowserError) {
        try await tab.printPage()
      } catch {
        lastError = error
      }
    }
  }

  /// Opens the page source in a new tab.
  public func viewSource() {
    guard let tab else { return }
    Task {
      do throws(BrowserError) {
        let source = try await tab.viewSourceURL()
        environment.openTab(url: source, profileID: profileID, opener: self)
      } catch {
        lastError = error
      }
    }
  }

  /// Bookmarks the page in the bookmarks bar, or removes its bookmarks.
  public func toggleBookmark() {
    guard let url else { return }
    do {
      try environment.bookmarks(for: profileID).toggle(url: url, title: title)
    } catch {
      lastError = error
    }
  }

  /// Clears `lastError`.
  public func dismissError() { lastError = nil }

}
