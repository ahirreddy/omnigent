#if os(iOS)
  import OmnigentCoreFFI
  import SwiftUI

  /// The remote tab on iPhone and iPad, laid out like Safari. On iPhone (compact width) the app's
  /// navigation bar steps aside: a floating address pill at the top (the page menu, the domain,
  /// reload) and a floating toolbar at the bottom (back, forward, share, take over or hand back,
  /// the tab overview), both Liquid Glass over the page, which runs under the toolbar and the
  /// home indicator. Scrolling the page down collapses the pill to the domain and hides the
  /// toolbar, as Safari does. On iPad the app's tab strip stays and one bar under it holds
  /// everything, like Safari's iPad toolbar. The status bar area takes the page's top colour.
  struct RemoteBrowserTouchLayout: View {
    let store: RemoteBrowserStore
    let reopen: (@MainActor (String) -> Void)?
    let showSessions: (@MainActor () -> Void)?
    let tabsButton: AnyView?

    @State private var collapse = RemoteChromeCollapse()
    @State private var editingAddress = false
    @State private var editingCustomSize = false
    @State private var dismissedHandoff: String?
    @State private var bottomInset: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      VStack(spacing: 0) {
        topBar
          .environment(\.colorScheme, barScheme)
        page
      }
      .background { band.ignoresSafeArea() }
      .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: {
        bottomInset = $0
      }
      .toolbarVisibility(isPhone ? .hidden : .automatic, for: .navigationBar)
      .animation(barAnimation, value: isCollapsed)
      .animation(barAnimation, value: editingAddress)
      .animation(barAnimation, value: hidesToolbar)
      .onChange(of: store.snapshot.scroll) { _, metrics in
        // The page's own scrolls while the agent drives would toggle the bars under the user.
        guard let metrics, store.canSendInput else { return }
        collapse.scrolled(metrics)
      }
      .onChange(of: store.navigation.url) { collapse.expand() }
      .remoteCustomSizeSheet(store: store, isPresented: $editingCustomSize)
    }

    private var isPhone: Bool { sizeClass == .compact }
    private var isCollapsed: Bool { isPhone && collapse.isCollapsed && !editingAddress }
    private var status: RemoteControlStatus {
      RemoteControlStatus(connection: store.snapshot.connection, control: store.snapshot.control)
    }

    /// The bottom toolbar steps aside while the page scrolls down, while the address is edited,
    /// and while the page's own field has the keyboard.
    private var hidesToolbar: Bool {
      isCollapsed || editingAddress
        || (store.canSendInput && store.snapshot.textInput.mode != .none)
    }

    private var barAnimation: Animation {
      reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35)
    }

    // MARK: Top

    /// The page's top colour behind the status bar and the pill, else the system background.
    private var band: Color {
      store.edgeColor.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
        ?? Color(uiColor: .systemBackground)
    }

    /// Light or dark bar content to read on the band.
    private var barScheme: ColorScheme {
      guard let color = store.edgeColor else { return systemScheme }
      return color.isDark ? .dark : .light
    }

    @Environment(\.colorScheme) private var systemScheme

    @ViewBuilder private var topBar: some View {
      if isCollapsed {
        Button {
          collapse.expand()
        } label: {
          RemoteDomainLabel(store: store)
            .font(.footnote.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the address bar and toolbar")
        .accessibilityIdentifier("remote-browser.addressBar.collapsed")
        .transition(.opacity)
      } else {
        GlassEffectContainer(spacing: 8) {
          HStack(spacing: 8) {
            if !isPhone, !editingAddress { navigationButtons }
            RemoteAddressPill(store: store, editing: $editingAddress) {
              RemotePageMenu(
                store: store, showSessions: isPhone ? showSessions : nil,
                editingCustomSize: $editingCustomSize)
            }
            if editingAddress {
              Button("Cancel") { editingAddress = false }
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityIdentifier("remote-browser.address.cancel")
                .transition(.opacity)
            } else if !isPhone {
              HStack(spacing: 8) {
                RemoteShareButton(store: store)
                RemoteControlButton(store: store)
              }
              .environment(\.remoteBarItemsFill, false)
              .buttonStyle(.glass)
              .buttonBorderShape(.circle)
              .controlSize(.large)
              .labelStyle(.iconOnly)
            }
          }
        }
        .padding(.horizontal, isPhone ? 16 : 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote-browser.addressBar")
        .transition(.opacity)
      }
    }

    /// Back and forward as glass circles (iPad).
    private var navigationButtons: some View {
      HStack(spacing: 8) {
        RemoteBackButton(store: store)
        RemoteForwardButton(store: store)
      }
      .environment(\.remoteBarItemsFill, false)
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      .controlSize(.large)
      .labelStyle(.iconOnly)
    }

    // MARK: Page

    private var page: some View {
      RemoteBrowserSurface(store: store)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlay { RemoteBrowserStatusOverlay(store: store, reopen: reopen) }
        // The page runs under the toolbar and the home indicator, as in Safari.
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay(alignment: .top) {
          if !isPhone { handoffBanner.padding(.top, 8) }
        }
        .overlay(alignment: .bottom) {
          VStack(spacing: 8) {
            notice
            if isPhone {
              handoffBanner
              if !hidesToolbar { toolbar.transition(toolbarTransition) }
            }
          }
          .padding(.bottom, bottomInset > 0 ? 0 : 8)
        }
    }

    private var toolbarTransition: AnyTransition {
      reduceMotion
        ? AnyTransition(OpacityTransition())
        : AnyTransition(MoveTransition(edge: .bottom).combined(with: OpacityTransition()))
    }

    /// Safari's bottom toolbar, with Omnigent's control and tab overview in place of Bookmarks
    /// and Tabs.
    private var toolbar: some View {
      HStack(spacing: 0) {
        RemoteBackButton(store: store)
        RemoteForwardButton(store: store)
        RemoteShareButton(store: store)
        RemoteControlButton(store: store)
        if let tabsButton {
          tabsButton.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .buttonStyle(.plain)
      .labelStyle(.iconOnly)
      .font(.title3)
      .frame(height: 50)
      .padding(.horizontal, 6)
      .glassEffect(.regular.interactive(), in: .capsule)
      .padding(.horizontal, 24)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("remote-browser.toolbar")
    }

    @ViewBuilder private var notice: some View {
      if let notice = store.notice {
        Label(notice, systemImage: "exclamationmark.bubble")
          .font(.callout)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .glassEffect(.regular, in: .capsule)
          .padding(.horizontal, 12)
          .accessibilityIdentifier("remote-browser.notice")
      }
    }

    /// The agent asking for the user (a sign-in, a CAPTCHA): a slim banner with Take Over until
    /// the user takes over or dismisses it; the control button keeps the pink.
    @ViewBuilder private var handoffBanner: some View {
      if case .agentNeedsYou(let reason) = status.kind, dismissedHandoff != reason {
        HStack(spacing: 10) {
          Image(systemName: "hand.raised.fill")
            .foregroundStyle(.pink)
            .accessibilityHidden(true)
          Text("Agent needs you: \(reason)")
            .font(.callout)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
          if status.canTakeOver {
            Button("Take Over") { store.takeControl() }
              .buttonStyle(.glassProminent)
              .tint(.pink)
              .accessibilityIdentifier("remote-browser.handoff.takeOver")
          }
          Button("Dismiss", systemImage: "xmark") { dismissedHandoff = reason }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote-browser.handoff")
        .transition(.opacity)
      }
    }
  }

#endif
