#if os(iOS)
  import OmnigentCoreFFI
  import SwiftUI

  /// Safari's page menu: the session list (where the app's navigation bar is hidden), control,
  /// the link, the zoom, the viewport and the user agent.
  struct RemotePageMenu: View {
    let store: RemoteBrowserStore
    let showSessions: (@MainActor () -> Void)?
    @Binding var editingCustomSize: Bool

    var body: some View {
      let status = RemoteControlStatus(
        connection: store.snapshot.connection, control: store.snapshot.control)
      Menu {
        if let showSessions {
          Button("Sessions", systemImage: "sidebar.leading") { showSessions() }
            .accessibilityIdentifier("remote-browser.menu.sessions")
        }
        Section(status.message) {
          if status.kind == .inControl {
            Button("Hand Back to Agent", systemImage: "hand.point.up.left.fill") {
              store.releaseControl()
            }
            .accessibilityIdentifier("remote-browser.menu.handBack")
          } else if status.canTakeOver {
            Button("Take Over", systemImage: "hand.point.up.left") { store.takeControl() }
              .accessibilityIdentifier("remote-browser.menu.takeOver")
          }
        }
        Section {
          Button("Copy Link", systemImage: "link") {
            store.pasteboard.write(store.navigation.url)
          }
          .disabled(RemoteAddressDisplay(url: store.navigation.url).isEmpty)
          .accessibilityIdentifier("remote-browser.copyLink")
          if let percent = store.zoomPercent {
            Button("Reset Zoom (\(percent)%)", systemImage: "arrow.down.right.and.arrow.up.left") {
              store.resetZoom()
            }
            .accessibilityIdentifier("remote-browser.resetZoom")
          }
        }
        Section {
          Menu {
            RemoteViewportMenuItems(store: store, editingCustomSize: $editingCustomSize)
          } label: {
            Label("Viewport: \(store.viewportMode.title)", systemImage: "aspectratio")
          }
          .accessibilityIdentifier("remote-browser.viewport")
          RemoteMobileSiteButton(store: store)
        }
        Section {
          Label("Profile: \(store.profile)", systemImage: "server.rack")
            .accessibilityIdentifier("remote-browser.profile")
        }
      } label: {
        Label("Page Menu", systemImage: "list.bullet.below.rectangle")
          .labelStyle(.iconOnly)
          .frame(width: 44, height: 44)
          .contentShape(Circle())
      }
      .menuIndicator(.hidden)
      .tint(.primary)
      .accessibilityIdentifier("remote-browser.menu")
    }
  }

  /// The address pill: the page menu, the domain (tap to edit the full address), and reload or
  /// stop, with the loading progress along its bottom edge. Editing shows the field with the
  /// whole address selected; Go loads it.
  struct RemoteAddressPill<PageMenu: View>: View {
    let store: RemoteBrowserStore
    @Binding var editing: Bool
    @ViewBuilder let pageMenu: () -> PageMenu

    @State private var text = ""
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool

    var body: some View {
      let navigation = store.navigation
      HStack(spacing: 2) {
        if editing {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
          field
        } else {
          pageMenu()
          Button {
            editing = true
          } label: {
            RemoteDomainLabel(store: store)
              .font(.body.weight(.semibold))
              .frame(maxWidth: .infinity, minHeight: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(store.isEnded)
          .accessibilityLabel(addressLabel)
          .accessibilityHint("Edits the address")
          .accessibilityIdentifier("remote-browser.address")
          reloadButton(loading: navigation.loading)
        }
      }
      .frame(height: 48)
      .glassEffect(.regular.interactive(), in: .capsule)
      .overlay(alignment: .bottom) { progress(navigation) }
      .frame(maxWidth: 720)
    }

    private var addressLabel: String {
      let display = RemoteAddressDisplay(url: store.navigation.url)
      return display.isEmpty ? "Search or enter website" : "Address, \(display.domain)"
    }

    private var field: some View {
      HStack(spacing: 4) {
        TextField("Search or enter website", text: $text, selection: $selection)
          .textFieldStyle(.plain)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .keyboardType(.webSearch)
          .submitLabel(.go)
          .focused($focused)
          .onSubmit {
            if store.submitAddress(text) { editing = false }
          }
          .accessibilityIdentifier("remote-browser.address")
        if !text.isEmpty {
          Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 44)
            .accessibilityIdentifier("remote-browser.address.clear")
        }
      }
      .padding(.trailing, 8)
      .onAppear {
        let url = store.navigation.url
        text = url == "about:blank" ? "" : url
        focused = true
      }
      .onChange(of: focused) { _, isFocused in
        guard isFocused else {
          editing = false
          return
        }
        // Safari selects the whole address once the field has focus, so typing replaces it.
        selection = TextSelection(range: text.startIndex..<text.endIndex)
      }
    }

    @ViewBuilder private func reloadButton(loading: Bool) -> some View {
      Group {
        if loading {
          Button("Stop", systemImage: "xmark") { store.navigate(.stop) }
            .accessibilityIdentifier("remote-browser.stop")
        } else {
          Button("Reload", systemImage: "arrow.clockwise") { store.navigate(.reload) }
            .disabled(store.isEnded)
            .accessibilityIdentifier("remote-browser.reload")
        }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.plain)
      .frame(width: 44, height: 44)
      .contentShape(Circle())
    }

    /// A thin line along the pill's bottom edge while the page loads.
    private func progress(_ navigation: RemoteBrowserNav) -> some View {
      GeometryReader { proxy in
        let fraction = navigation.loading ? max(0.05, min(navigation.progress, 1)) : 0
        Capsule()
          .fill(.tint)
          .frame(width: max(0, proxy.size.width - 40) * fraction, height: 2.5)
          .padding(.leading, 20)
          .frame(maxHeight: .infinity, alignment: .bottom)
      }
      .opacity(navigation.loading ? 1 : 0)
      .allowsHitTesting(false)
      .accessibilityElement()
      .accessibilityLabel("Loading")
      .accessibilityValue(Text(navigation.progress, format: .percent.precision(.fractionLength(0))))
      .accessibilityIdentifier("remote-browser.progress")
    }
  }

  /// The domain with a lock for HTTPS, or "Search or enter website" with a magnifier.
  struct RemoteDomainLabel: View {
    let store: RemoteBrowserStore

    var body: some View {
      let display = RemoteAddressDisplay(url: store.navigation.url)
      HStack(spacing: 4) {
        if display.isEmpty {
          Image(systemName: "magnifyingglass")
            .accessibilityHidden(true)
          Text("Search or enter website")
        } else {
          if display.isSecure {
            Image(systemName: "lock.fill")
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityLabel("Secure")
          }
          Text(display.domain)
        }
      }
      .foregroundStyle(display.isEmpty ? .secondary : .primary)
      .lineLimit(1)
      .truncationMode(.middle)
    }
  }

  /// Back, dimmed when there is nowhere to go.
  struct RemoteBackButton: View {
    let store: RemoteBrowserStore

    var body: some View {
      let enabled = store.navigation.canGoBack && !store.isEnded
      Button("Back", systemImage: "chevron.backward") { store.navigate(.back) }
        .disabled(!enabled)
        .modifier(RemoteBarItem(enabled: enabled))
        .accessibilityIdentifier("remote-browser.back")
    }
  }

  /// Forward, dimmed when there is nowhere to go.
  struct RemoteForwardButton: View {
    let store: RemoteBrowserStore

    var body: some View {
      let enabled = store.navigation.canGoForward && !store.isEnded
      Button("Forward", systemImage: "chevron.forward") { store.navigate(.forward) }
        .disabled(!enabled)
        .modifier(RemoteBarItem(enabled: enabled))
        .accessibilityIdentifier("remote-browser.forward")
    }
  }

  /// The share sheet for the page's address.
  struct RemoteShareButton: View {
    let store: RemoteBrowserStore

    var body: some View {
      let url =
        RemoteAddressDisplay(url: store.navigation.url).isEmpty
        ? nil : URL(string: store.navigation.url)
      Group {
        if let url {
          ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            .modifier(RemoteBarItem(enabled: true))
        } else {
          Button("Share", systemImage: "square.and.arrow.up") {}
            .disabled(true)
            .modifier(RemoteBarItem(enabled: false))
        }
      }
      .accessibilityIdentifier("remote-browser.share")
    }
  }

  /// Take Over or Hand Back, with a glyph that says who drives: an outlined hand while the agent
  /// browses (pink when it needs you), a filled hand on a tinted circle while you are in control.
  struct RemoteControlButton: View {
    let store: RemoteBrowserStore

    var body: some View {
      let status = RemoteControlStatus(
        connection: store.snapshot.connection, control: store.snapshot.control)
      Group {
        if status.kind == .inControl {
          Button("Hand Back to Agent", systemImage: "hand.point.up.left.fill") {
            store.releaseControl()
          }
          .foregroundStyle(.tint)
          .background { Circle().fill(.tint.opacity(0.18)).frame(width: 40, height: 40) }
          .modifier(RemoteBarItem(enabled: true, styled: false))
          .accessibilityIdentifier("remote-browser.handBack")
        } else if status.canTakeOver {
          Button(
            "Take Over", systemImage: status.needsYou ? "hand.raised.fill" : "hand.point.up.left"
          ) {
            store.takeControl()
          }
          .foregroundStyle(status.needsYou ? AnyShapeStyle(.pink) : AnyShapeStyle(.primary))
          .modifier(RemoteBarItem(enabled: true, styled: false))
          .accessibilityIdentifier("remote-browser.takeOver")
        } else {
          Button(
            status.message, systemImage: status.kind == .viewing ? "eye" : "hand.point.up.left"
          ) {}
          .disabled(true)
          .modifier(RemoteBarItem(enabled: false))
          .accessibilityIdentifier("remote-browser.control")
        }
      }
      .accessibilityValue(status.message)
    }
  }

  /// A bar item: fills its share of the bottom toolbar (not the iPad bar's glass circles), dimmed
  /// when disabled.
  struct RemoteBarItem: ViewModifier {
    let enabled: Bool
    var styled = true
    @Environment(\.remoteBarItemsFill) private var fills

    func body(content: Content) -> some View {
      Group {
        if styled {
          content.foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        } else {
          content
        }
      }
      .frame(maxWidth: fills ? .infinity : nil, minHeight: fills ? 44 : nil)
      .contentShape(Rectangle())
    }
  }

  extension EnvironmentValues {
    /// Whether bar items share the bottom toolbar's width.
    @Entry var remoteBarItemsFill = true
  }
#endif
