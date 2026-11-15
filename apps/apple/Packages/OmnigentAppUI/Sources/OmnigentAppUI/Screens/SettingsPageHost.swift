#if os(macOS)
  import AppKit
  import OmnigentUIComponents
  public import SwiftUI

  extension View {
    /// Shows a window's Settings page over this view, in the whole window, while `navigator`
    /// presents it. The view stays built underneath, so going back finds its session, tabs,
    /// scroll positions and drafts as they were. Everything in the view that opens Settings
    /// (the sidebar's gear, Appearance, settings links) shows the page.
    /// - Parameters:
    ///   - navigator: The window's navigator.
    ///   - page: The Settings page.
    /// - Returns: The view, or the page over it.
    public func settingsPage<Page: View>(
      _ navigator: SettingsNavigator, @ViewBuilder page: @escaping () -> Page
    ) -> some View {
      modifier(SettingsPageHost(navigator: navigator, page: page))
    }

    /// Leaves Settings when the window goes somewhere else under the page, as Command-N or a
    /// pinned session's shortcut takes it. `place` is read here, so a change renders this
    /// modifier and not the window.
    /// - Parameters:
    ///   - navigator: The window's navigator.
    ///   - place: What the window shows.
    /// - Returns: The view.
    public func leavesSettings<Place: Equatable>(
      _ navigator: SettingsNavigator, onChangeOf place: Binding<Place>
    ) -> some View {
      modifier(SettingsLeftOnNavigation(navigator: navigator, place: place))
    }
  }

  private struct SettingsPageHost<Page: View>: ViewModifier {
    let navigator: SettingsNavigator
    let page: () -> Page
    @State private var screen = SettingsScreenPresenter()
    @State private var appearance = AppearanceSettingsPresenter()

    func body(content: Content) -> some View {
      let isShown = navigator.isPresented
      screen.open = { [navigator] in navigator.open() }
      appearance.open = { [navigator] in navigator.open(.tab(SettingsNavigator.appearanceTab)) }
      return ZStack {
        content
          .environment(\.openSettingsAt, .settingsPage(navigator))
          .environment(\.openSettingsPage, OpenSettingsScreenAction(presenter: screen))
          .environment(
            \.openAppearanceSettings, OpenAppearanceSettingsAction(presenter: appearance)
          )
          .opacity(isShown ? 0 : 1)
          .allowsHitTesting(!isShown)
          .accessibilityHidden(isShown)
        if isShown {
          page().background { SettingsWindowTakeover().frame(width: 0, height: 0) }
        }
      }
    }
  }

  private struct SettingsLeftOnNavigation<Place: Equatable>: ViewModifier {
    let navigator: SettingsNavigator
    @Binding var place: Place

    func body(content: Content) -> some View {
      content.onChange(of: place) { navigator.close() }
    }
  }

  /// Makes the window Settings' while the page shows: its title says Settings, the toolbar of
  /// the covered content (its tabs and buttons) is hidden, and the keyboard leaves the covered
  /// content, so typing never reaches a hidden composer. Leaving puts all three back.
  struct SettingsWindowTakeover: NSViewRepresentable {
    /// The window's title while it shows Settings.
    static let title = "Settings"

    func makeNSView(context: Context) -> TakeoverView { TakeoverView() }

    func updateNSView(_ view: TakeoverView, context: Context) {}

    static func dismantleNSView(_ view: TakeoverView, coordinator: ()) {
      view.handBack()
    }

    final class TakeoverView: NSView {
      private weak var covered: NSWindow?
      private weak var previousResponder: NSResponder?
      /// The title and subtitle (a session's status) the covered content last gave the window.
      private var coveredTitle = ""
      private var coveredSubtitle = ""
      /// The toolbars this hid, and whether each saved its own configuration.
      private var hiddenToolbars: [(toolbar: NSToolbar, autosaves: Bool)] = []
      private var observations: [NSKeyValueObservation] = []

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // `NSView.window` is `unowned(unsafe)`; it is read while AppKit attaches the view.
        guard let window = unsafe self.window, covered == nil else { return }
        covered = window
        previousResponder = window.firstResponder
        window.makeFirstResponder(nil)
        (coveredTitle, coveredSubtitle) = (window.title, window.subtitle)
        keepTitle(of: window)
        hideToolbar(of: window)
        // The covered content still names the window and swaps its toolbar as it changes.
        observations = [
          window.observe(\.title) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.keepTitle(of: window) }
          },
          window.observe(\.subtitle) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.keepTitle(of: window) }
          },
          window.observe(\.toolbar) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.hideToolbar(of: window) }
          },
        ]
      }

      /// Titles the window Settings, with no subtitle, remembering what the content called it.
      private func keepTitle(of window: NSWindow) {
        if window.title != SettingsWindowTakeover.title {
          coveredTitle = window.title
          window.title = SettingsWindowTakeover.title
        }
        if !window.subtitle.isEmpty {
          coveredSubtitle = window.subtitle
          window.subtitle = ""
        }
      }

      /// Hides the window's toolbar, leaving the title bar. Its hidden state is not saved: a
      /// quit from Settings must not start the next launch without a toolbar.
      private func hideToolbar(of window: NSWindow) {
        guard let toolbar = window.toolbar, toolbar.isVisible else { return }
        hiddenToolbars.append((toolbar, toolbar.autosavesConfiguration))
        toolbar.autosavesConfiguration = false
        toolbar.isVisible = false
      }

      /// Gives the window back: its own title, the toolbars this hid, and the keyboard to the
      /// view that had it, if that view is still in the window.
      func handBack() {
        observations = []
        guard let window = covered else { return }
        covered = nil
        window.title = coveredTitle
        window.subtitle = coveredSubtitle
        for (toolbar, autosaves) in hiddenToolbars {
          toolbar.isVisible = true
          toolbar.autosavesConfiguration = autosaves
        }
        hiddenToolbars = []
        guard let view = previousResponder as? NSView, unsafe view.window === window else { return }
        window.makeFirstResponder(view)
      }
    }
  }
#endif
