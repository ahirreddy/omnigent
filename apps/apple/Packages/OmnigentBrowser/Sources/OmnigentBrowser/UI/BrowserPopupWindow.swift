#if os(macOS)
  internal import AppKit
  internal import SwiftUI

  /// A window for a popup or new-tab request when the app has no tab strip handler
  /// (`BrowserPromptPresenter.onOpenPopup`). The window closes when the page calls
  /// `window.close()`, and closing the window closes the tab.
  final class BrowserPopupWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [BrowserPopupWindowController] = []
    private let tab: any BrowserTab

    static func open(_ popup: BrowserPopup, presenter: BrowserPromptPresenter) {
      let controller = BrowserPopupWindowController(popup: popup, presenter: presenter)
      open.append(controller)
      controller.showWindow(nil)
    }

    private init(popup: BrowserPopup, presenter: BrowserPromptPresenter) {
      tab = popup.tab
      let size = popup.requestedSize ?? CGSize(width: 900, height: 700)
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
        defer: false)
      window.title = popup.targetURL?.host(percentEncoded: false) ?? "New Window"
      window.isReleasedWhenClosed = false
      let preferences = BrowserPreferences(
        defaultEngine: popup.tab.engineKind, allowedEngines: [popup.tab.engineKind])
      let controller = BrowserController(
        adopting: popup.tab, preferences: preferences, provider: PopupProvider(tab: popup.tab),
        presenter: presenter)
      window.contentView = NSHostingView(
        rootView: BrowserView(controller: controller, showsToolbar: !popup.disposition.wantsWindow)
          .frame(minWidth: 320, minHeight: 240))
      window.center()
      super.init(window: window)
      window.delegate = self
      observeClose()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      nil
    }

    private func observeClose() {
      withObservationTracking {
        _ = tab.state.isClosed
      } onChange: { [weak self] in
        // A tab closes once and never reopens, so the one change is the close.
        Task { @MainActor in self?.window?.close() }
      }
    }

    func windowWillClose(_ notification: Notification) {
      tab.close()
      Self.open.removeAll { $0 === self }
    }
  }

  /// A provider that only knows the popup's engine; the window never switches engines.
  final class PopupProvider: BrowserEngineProvider {
    private let tab: any BrowserTab

    init(tab: any BrowserTab) {
      self.tab = tab
    }

    var offeredEngines: [BrowserEngineKind] { [tab.engineKind] }

    func availability(of kind: BrowserEngineKind) -> BrowserEngineAvailability {
      kind == tab.engineKind
        ? .available
        : .unavailable(.engineNotBundled(kind, reason: "Popup windows keep their engine."))
    }

    func engine(for kind: BrowserEngineKind) throws(BrowserError) -> any BrowserEngine {
      throw .engineNotBundled(kind, reason: "Popup windows keep their engine.")
    }
  }
#endif
