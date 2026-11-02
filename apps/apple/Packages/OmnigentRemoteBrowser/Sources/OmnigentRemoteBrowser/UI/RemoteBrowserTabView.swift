import OmnigentCoreFFI
public import SwiftUI

/// A remote browser tab. On the Mac: the local browser tab's toolbar layout (back, forward,
/// reload, address field), loading progress, a control strip, and the video surface. On iPhone
/// and iPad: Safari's layout (`RemoteBrowserTouchLayout`). The connecting, failed and ended
/// states sit over the video.
public struct RemoteBrowserTabView: View {
  private let store: RemoteBrowserStore
  private let reopen: (@MainActor (String) -> Void)?
  private let showSessions: (@MainActor () -> Void)?
  private let tabsButton: AnyView?

  /// Creates the view.
  /// - Parameters:
  ///   - store: The tab.
  ///   - reopen: Opens a new remote tab at a URL, offered once this one ended; `nil` hides it.
  ///   - showSessions: Shows the session list where the tab hides the app's navigation bar
  ///     (iPhone); `nil` leaves it out of the page menu.
  public init(
    store: RemoteBrowserStore, reopen: (@MainActor (String) -> Void)? = nil,
    showSessions: (@MainActor () -> Void)? = nil
  ) {
    self.store = store
    self.reopen = reopen
    self.showSessions = showSessions
    tabsButton = nil
  }

  /// Creates the view with the app's tab overview button in the iPhone toolbar.
  /// - Parameters:
  ///   - store: The tab.
  ///   - reopen: Opens a new remote tab at a URL, offered once this one ended; `nil` hides it.
  ///   - showSessions: Shows the session list where the tab hides the app's navigation bar.
  ///   - tabsButton: The app's tab overview button, in Safari's Tabs place.
  public init(
    store: RemoteBrowserStore, reopen: (@MainActor (String) -> Void)? = nil,
    showSessions: (@MainActor () -> Void)? = nil,
    @ViewBuilder tabsButton: () -> some View
  ) {
    self.store = store
    self.reopen = reopen
    self.showSessions = showSessions
    self.tabsButton = AnyView(tabsButton())
  }

  /// The view body.
  public var body: some View {
    layout
      .onAppear { store.setVisible(true) }
      .onDisappear { store.setVisible(false) }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("remote-browser.tab")
  }

  @ViewBuilder private var layout: some View {
    #if os(iOS)
      RemoteBrowserTouchLayout(
        store: store, reopen: reopen, showSessions: showSessions, tabsButton: tabsButton)
    #else
      VStack(spacing: 0) {
        RemoteBrowserToolbar(store: store)
          .zIndex(1)
        ProgressView(value: navigation.loading ? max(0.05, navigation.progress) : 0)
          .progressViewStyle(.linear)
          .frame(height: 2)
          .opacity(navigation.loading ? 1 : 0)
          .accessibilityIdentifier("remote-browser.progress")
        Divider()
        RemoteBrowserControlStrip(store: store)
        RemoteBrowserSurface(store: store)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.background)
          .overlay { RemoteBrowserStatusOverlay(store: store, reopen: reopen) }
          .overlay(alignment: .bottom) {
            if let notice = store.notice {
              Label(notice, systemImage: "exclamationmark.bubble")
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(12)
                .accessibilityIdentifier("remote-browser.notice")
            }
          }
      }
    #endif
  }

  private var navigation: RemoteBrowserNav { store.navigation }
}

#if os(macOS)
  /// Back, forward, reload or stop, the address field and the profile, laid out like the local
  /// browser's `BrowserTabToolbar`.
  struct RemoteBrowserToolbar: View {
    let store: RemoteBrowserStore

    var body: some View {
      let navigation = store.navigation
      let live = !store.isEnded
      HStack(spacing: 6) {
        Button("Back", systemImage: "chevron.backward") { store.navigate(.back) }
          .disabled(!navigation.canGoBack || !live)
          .accessibilityIdentifier("remote-browser.back")
        Button("Forward", systemImage: "chevron.forward") { store.navigate(.forward) }
          .disabled(!navigation.canGoForward || !live)
          .accessibilityIdentifier("remote-browser.forward")
        if navigation.loading {
          Button("Stop", systemImage: "xmark") { store.navigate(.stop) }
            .accessibilityIdentifier("remote-browser.stop")
        } else {
          Button("Reload", systemImage: "arrow.clockwise") { store.navigate(.reload) }
            .disabled(!live)
            .accessibilityIdentifier("remote-browser.reload")
        }
        RemoteAddressField(store: store)
        RemoteViewportMenu(store: store)
        Label(store.profile, systemImage: "server.rack")
          .labelStyle(.titleAndIcon)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .help("Remote browser profile: \(store.profile)")
          .accessibilityIdentifier("remote-browser.profile")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
    }
  }

  /// The address field: shows the page URL; Return loads what was typed, as a URL or a search.
  struct RemoteAddressField: View {
    let store: RemoteBrowserStore
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
      let url = store.navigation.url
      HStack(spacing: 6) {
        Image(systemName: url.hasPrefix("https:") ? "lock.fill" : "globe")
          .foregroundStyle(.secondary)
          .frame(width: 16, height: 16)
          .accessibilityLabel(url.hasPrefix("https:") ? "Secure" : "Page")
        TextField("Search or enter address", text: $text)
          .textFieldStyle(.plain)
          .autocorrectionDisabled()
          .focused($focused)
          .onSubmit {
            if store.submitAddress(text) { focused = false }
          }
          .onKeyPress(.escape) {
            revert()
            focused = false
            return .handled
          }
          .disabled(store.isEnded)
          .accessibilityIdentifier("remote-browser.address")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(.quaternary.opacity(focused ? 0.9 : 0.6), in: Capsule())
      .overlay {
        if focused { Capsule().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5) }
      }
      .onChange(of: url, initial: true) { revert() }
      .onChange(of: focused) { _, isFocused in
        if !isFocused { revert() }
      }
    }

    private func revert() {
      let url = store.navigation.url
      text = url == "about:blank" ? "" : url
    }
  }

  /// Who drives the page, with Take Over / Hand Back for the owner.
  struct RemoteBrowserControlStrip: View {
    let store: RemoteBrowserStore

    var body: some View {
      let status = RemoteControlStatus(
        connection: store.snapshot.connection, control: store.snapshot.control)
      if status.kind != .unavailable {
        HStack(spacing: 8) {
          Image(systemName: store.canSendInput ? "hand.point.up.left" : "eye")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text(status.message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer(minLength: 0)
          if status.kind == .inControl {
            Button("Hand Back to Agent") { store.releaseControl() }
              .controlSize(.small)
              .accessibilityIdentifier("remote-browser.handBack")
          } else if status.canTakeOver {
            Button("Take Over") { store.takeControl() }
              .controlSize(.small)
              .accessibilityIdentifier("remote-browser.takeOver")
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote-browser.control")
      }
    }
  }
#endif

/// Connecting, reconnecting, failed and ended states over the video.
struct RemoteBrowserStatusOverlay: View {
  let store: RemoteBrowserStore
  let reopen: (@MainActor (String) -> Void)?

  var body: some View {
    Group {
      switch store.snapshot.connection {
      case .idle, .connecting:
        ProgressView("Connecting to the remote browser\u{2026}")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.background)
          .accessibilityIdentifier("remote-browser.connecting")
      case .reconnecting(let reason, let failures, _):
        VStack {
          Label(
            "Reconnecting (\(failures)): \(reason.remoteBrowserMessage)",
            systemImage: "wifi.exclamationmark"
          )
          .font(.callout)
          .padding(8)
          .background(.regularMaterial, in: Capsule())
          .padding(.top, 12)
          Spacer()
        }
        .accessibilityIdentifier("remote-browser.reconnecting")
      case .failed(_, let message, let requiresSignIn):
        unavailable(
          "Remote Browser Unavailable",
          detail: requiresSignIn ? "\(message) Sign in again to continue." : message)
      case .closed:
        ended
      case .attached, .stopped:
        Color.clear.allowsHitTesting(false)
      }
    }
  }

  private var ended: some View {
    ContentUnavailableView {
      Label("This remote tab ended", systemImage: "globe.badge.chevron.backward")
    } description: {
      Text(
        store.lastURL.isEmpty ? "The page is no longer open on the agent's machine." : store.lastURL
      )
      .textSelection(.enabled)
    } actions: {
      if let reopen {
        Button("Reopen") { reopen(store.lastURL) }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("remote-browser.reopen")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("remote-browser.ended")
  }

  private func unavailable(_ title: String, detail: String) -> some View {
    ContentUnavailableView {
      Label(title, systemImage: "exclamationmark.triangle")
    } description: {
      Text(detail).textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .accessibilityIdentifier("remote-browser.unavailable")
  }
}

/// SwiftUI host for ``RemoteBrowserView``.
public struct RemoteBrowserSurface {
  private let store: RemoteBrowserStore

  /// Creates the surface.
  /// - Parameter store: The tab.
  public init(store: RemoteBrowserStore) {
    self.store = store
  }
}

#if os(macOS)
  extension RemoteBrowserSurface: NSViewRepresentable {
    /// Creates the view.
    public func makeNSView(context: Context) -> RemoteBrowserView {
      RemoteBrowserView(store: store)
    }

    /// Nothing to update; the view observes its store.
    public func updateNSView(_ nsView: RemoteBrowserView, context: Context) {}
  }
#else
  extension RemoteBrowserSurface: UIViewRepresentable {
    /// Creates the view.
    public func makeUIView(context: Context) -> RemoteBrowserView {
      RemoteBrowserView(store: store)
    }

    /// Nothing to update; the view observes its store.
    public func updateUIView(_ uiView: RemoteBrowserView, context: Context) {}
  }
#endif
