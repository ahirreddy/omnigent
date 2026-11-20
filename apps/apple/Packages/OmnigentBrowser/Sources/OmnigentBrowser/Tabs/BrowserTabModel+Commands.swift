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

  /// Whether the tab is still on a new tab's empty page. There is nothing to type into, so the
  /// address field takes the keyboard when the tab shows; on any other page the page does.
  public var showsEmptyPage: Bool {
    guard let url else { return true }
    return !BrowserRestorePlaceholder.isRestorable(url)
  }

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

  /// The page's selection for seeding find: the focused text field's selected range, else the
  /// document selection; never a password field's.
  static let findSeedScript = """
    (() => {
      const active = document.activeElement;
      const types = ["text", "search", "url", "tel", "email"];
      const isControl = active instanceof HTMLTextAreaElement || active instanceof HTMLInputElement;
      const isField = active instanceof HTMLTextAreaElement
        || (active instanceof HTMLInputElement && types.includes(active.type));
      if (isField && active.selectionEnd > active.selectionStart) {
        return active.value.slice(active.selectionStart, active.selectionEnd);
      }
      return isControl ? "" : String(window.getSelection()?.toString() ?? "");
    })()
    """

  /// Find (Command-F): shows the bar with the page's selected line as its query, searched and
  /// selected so typing replaces it. Pressed in the field, it keeps what was typed; a query typed
  /// while the selection is read wins, and a later Find replaces an earlier one's read.
  public func showFindBarSeedingSelection() async {
    if find.isVisible, find.isFieldFocused {
      showFindBar()
      return
    }
    find.seedGeneration += 1
    let generation = find.seedGeneration
    let typed = find.query
    let wasVisible = find.isVisible
    var seed: String?
    if let tab {
      do {
        if case .string(let text) = try await tab.evaluateJavaScript(Self.findSeedScript) {
          seed = BrowserFindModel.seed(fromSelection: text)
        }
      } catch {
        lastError = error
      }
    }
    guard generation == find.seedGeneration else { return }
    let seeded = seed.flatMap { find.query == typed ? $0 : nil }
    if let seeded {
      find.query = seeded
      find.selectAllRequest += 1
    }
    showFindBar()
    // A shown bar searches its changed query itself; a newly shown one starts here.
    if seeded != nil, !wasVisible { await findNext(forward: true) }
  }

  /// Highlights the next (or previous) match of `find.query`.
  public func findNext(forward: Bool = true) async {
    guard let tab, !find.query.isEmpty else {
      find.result = nil
      tab?.stopFinding()
      return
    }
    do {
      find.result = try await tab.find(
        find.query, forward: forward, caseSensitive: find.caseSensitive)
    } catch {
      lastError = error
    }
  }

  /// Makes the page's selected text the text to find, for Find Next and Find Previous (Edit >
  /// Use Selection for Find). A page with nothing selected keeps the text it had.
  public func useSelectionForFind() async {
    guard let tab else { return }
    do {
      let selection = try await tab.evaluateJavaScript("window.getSelection().toString()")
      if case .string(let text) = selection, !text.isEmpty { find.query = text }
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
