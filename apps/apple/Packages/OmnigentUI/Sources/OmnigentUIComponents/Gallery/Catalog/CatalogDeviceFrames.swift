import SwiftUI

/// A page on a device: the app's area with the hardware's safe areas, the status bar, the
/// Dynamic Island, the home indicator and the Duo's crease, inside a drawn bezel. Without a
/// frame it is the bare app area (the crease stays: it is part of the screen).
struct CatalogDeviceView<Content: View>: View {
  let screen: CatalogScreen
  let isFramed: Bool
  @ViewBuilder var content: Content

  private var showsHardware: Bool { isFramed && screen.device != .mac }

  var body: some View {
    if showsHardware {
      display
        .padding(screen.bezel)
        .background { CatalogBezel(screen: screen) }
    } else {
      app
    }
  }

  /// The app's area.
  private var app: some View {
    ZStack(alignment: .topLeading) {
      Color.clear.themeCanvas()
      content
        .catalogSafeArea(showsHardware ? screen.safeArea : EdgeInsets())
        .frame(width: screen.size.width, height: screen.size.height)
      if showsHardware, screen.safeArea.top > 0 {
        // Scrolled content passes under the status bar onto the canvas, as with the app's
        // hard scroll edge.
        Color.clear.themeCanvas().frame(height: screen.safeArea.top)
      }
      if let crease = screen.crease {
        CatalogCrease()
          .frame(width: CatalogCrease.width, height: crease.height)
          .offset(x: crease.midX - CatalogCrease.width / 2)
      }
    }
    .frame(width: screen.size.width, height: screen.size.height)
    .clipped()
  }

  /// The whole display: the app, or for Split View the app beside the divider and another app.
  private var display: some View {
    ZStack(alignment: .topLeading) {
      if screen.device.family == .split {
        HStack(spacing: 0) {
          app
          CatalogSplitDivider()
          CatalogOtherApp()
        }
      } else {
        app
      }
      CatalogStatusBar(screen: screen)
      CatalogSensorHousing(screen: screen)
      CatalogHomeIndicator(screen: screen)
    }
    .frame(width: screen.displaySize.width, height: screen.displaySize.height)
    .clipShape(screen.displayShape)
    .accessibilityElement(children: .contain)
  }
}

extension View {
  /// Gives the content the hardware's safe-area insets, as a window on the device would. The
  /// side insets (landscape iPhone) are padding: a Mac-hosted scroll view would otherwise lay
  /// its rows under the Dynamic Island, where iOS insets them.
  fileprivate func catalogSafeArea(_ insets: EdgeInsets) -> some View {
    safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: insets.top) }
      .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: insets.bottom) }
      .padding(.leading, insets.leading)
      .padding(.trailing, insets.trailing)
  }
}

/// The device body behind the display, with the SE's home button and earpiece.
private struct CatalogBezel: View {
  let screen: CatalogScreen

  var body: some View {
    let side = min(screen.bezel.leading, screen.bezel.top)
    let display = screen.cornerRadii
    let radii =
      screen.device == .iPhoneSE
      ? RectangleCornerRadii(topLeading: 52, bottomLeading: 52, bottomTrailing: 52, topTrailing: 52)
      : RectangleCornerRadii(
        topLeading: display.topLeading + side, bottomLeading: display.bottomLeading + side,
        bottomTrailing: display.bottomTrailing + side, topTrailing: display.topTrailing + side)
    let shape = UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
    ZStack {
      shape.fill(Color(white: 0.09))
      shape.strokeBorder(Color(white: 0.38), lineWidth: 2)
      if screen.device == .iPhoneSE { seControls }
    }
    .accessibilityHidden(true)
  }

  /// The home button in the chin and the earpiece in the forehead.
  @ViewBuilder private var seControls: some View {
    let landscape = screen.isLandscape
    let button = Circle().strokeBorder(Color(white: 0.3), lineWidth: 3).frame(width: 56, height: 56)
    let earpiece = Capsule().fill(Color(white: 0.2))
      .frame(width: landscape ? 6 : 52, height: landscape ? 52 : 6)
    if landscape {
      HStack {
        earpiece.padding(.leading, 42)
        Spacer()
        button.padding(.trailing, 18)
      }
    } else {
      VStack {
        earpiece.padding(.top, 42)
        Spacer()
        button.padding(.bottom, 18)
      }
    }
  }
}

/// Time, signal, Wi-Fi and battery, in the status bar's height for the device.
private struct CatalogStatusBar: View {
  let screen: CatalogScreen

  var body: some View {
    Group {
      switch (screen.device.family, screen.device, screen.isLandscape) {
      case (.phone, .iPhone, false): islandBar
      case (.phone, .iPhoneSE, false): seBar
      case (.duo, _, _) where !screen.isUnfolded: duoColumn
      case (.pad, _, _), (.split, _, _), (.duo, _, _):
        // Clear of the corner: the unfolded Duo's are far rounder than an iPad's.
        let padding = max(22, screen.cornerRadii.topLeading * 0.7)
        wideBar(font: 13, height: screen.safeArea.top, padding: padding, date: true)
      default: EmptyView()
      }
    }
    .foregroundStyle(.primary)
    .accessibilityHidden(true)
  }

  private var icons: some View {
    HStack(spacing: 5) {
      Image(systemName: "cellularbars").accessibilityHidden(true)
      Image(systemName: "wifi").accessibilityHidden(true)
      Image(systemName: "battery.100").accessibilityHidden(true)
    }
  }

  /// The time and icons either side of the Dynamic Island.
  private var islandBar: some View {
    HStack(spacing: 0) {
      Text(verbatim: "9:41").frame(maxWidth: .infinity)
      Color.clear.frame(width: CatalogSensorHousing.island.width + 24)
      icons.frame(maxWidth: .infinity)
    }
    .font(.system(size: 16, weight: .semibold))
    .frame(width: screen.displaySize.width, height: CatalogSensorHousing.island.height)
    .padding(.top, CatalogSensorHousing.islandTop)
  }

  /// The folded Duo's status bar: a column on the right, the time and icons under the island.
  private var duoColumn: some View {
    VStack(spacing: 10) {
      Text(verbatim: "9:41").font(.system(size: 15, weight: .semibold))
      Image(systemName: "wifi").accessibilityHidden(true)
      Image(systemName: "battery.100").accessibilityHidden(true)
    }
    .font(.system(size: 13, weight: .semibold))
    .padding(.top, DuoDisplays.outerIsland.maxY + 10)
    .frame(width: screen.safeArea.trailing, height: screen.displaySize.height, alignment: .top)
    .frame(width: screen.displaySize.width, alignment: .trailing)
  }

  private var seBar: some View {
    HStack {
      HStack(spacing: 4) {
        Image(systemName: "cellularbars").accessibilityHidden(true)
        Image(systemName: "wifi").accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(verbatim: "9:41")
      Image(systemName: "battery.100").accessibilityHidden(true).frame(
        maxWidth: .infinity, alignment: .trailing)
    }
    .font(.system(size: 12, weight: .semibold))
    .padding(.horizontal, 6)
    .frame(width: screen.displaySize.width, height: screen.safeArea.top)
  }

  private func wideBar(font: CGFloat, height: CGFloat, padding: CGFloat, date: Bool = false)
    -> some View
  {
    HStack {
      Text(verbatim: date ? "9:41  Mon Nov 2" : "9:41")
      Spacer()
      icons
    }
    .font(.system(size: font, weight: .semibold))
    .padding(.horizontal, padding)
    .frame(width: screen.displaySize.width, height: height)
  }
}

/// The Dynamic Island.
private struct CatalogSensorHousing: View {
  static let island = CGSize(width: 126, height: 37)
  static let islandTop: CGFloat = 11
  let screen: CatalogScreen

  var body: some View {
    Group {
      switch (screen.device, screen.isLandscape) {
      case (.iPhone, false):
        Capsule().fill(.black)
          .frame(width: Self.island.width, height: Self.island.height)
          .padding(.top, Self.islandTop)
          .frame(width: screen.displaySize.width, alignment: .top)
      case (.iPhone, true):
        Capsule().fill(.black)
          .frame(width: Self.island.height, height: Self.island.width)
          .padding(.leading, Self.islandTop)
          .frame(height: screen.displaySize.height, alignment: .leading)
      case (.duo, _) where !screen.isUnfolded:
        let island = DuoDisplays.outerIsland
        Capsule().fill(.black)
          .frame(width: island.width, height: island.height)
          .offset(x: island.minX, y: island.minY)
          .frame(
            width: screen.displaySize.width, height: screen.displaySize.height,
            alignment: .topLeading)
      default:
        EmptyView()
      }
    }
    .accessibilityHidden(true)
  }
}

/// The home indicator above the bottom edge (not on the SE, which has a button).
private struct CatalogHomeIndicator: View {
  let screen: CatalogScreen

  var body: some View {
    if screen.safeArea.bottom > 0 {
      let isPhoneSized = screen.device.family == .phone || screen.hingePosture == .closed
      let width: CGFloat = isPhoneSized ? 139 : 300
      Capsule()
        .fill(.primary)
        .frame(width: min(width, screen.displaySize.width / 2), height: 5)
        .padding(.bottom, 8)
        .frame(
          width: screen.displaySize.width, height: screen.displaySize.height, alignment: .bottom
        )
        .accessibilityHidden(true)
    }
  }
}

/// The unfolded Duo's crease: a faint shading over the continuous display where it folds.
private struct CatalogCrease: View {
  static let width: CGFloat = 10

  var body: some View {
    LinearGradient(
      colors: [.clear, .primary.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing
    )
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// The Split View divider with its handle.
private struct CatalogSplitDivider: View {
  var body: some View {
    ZStack {
      Color.black
      Capsule().fill(Color(white: 0.55)).frame(width: 4, height: 44)
    }
    .frame(width: CatalogScreen.splitDivider)
    .accessibilityHidden(true)
  }
}

/// The other app sharing the screen in Split View.
private struct CatalogOtherApp: View {
  var body: some View {
    ZStack {
      Rectangle().fill(.background.secondary)
      Label("Another app", systemImage: "square.grid.2x2")
        .font(.callout)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

extension View {
  /// On a touch screen rendered on the Mac, draws the navigation bar a navigation stack would
  /// show on the device (the Mac puts it in the window toolbar, which a canvas does not have).
  func catalogNavigationBar(_ title: String) -> some View {
    modifier(CatalogNavigationBarModifier(title: title))
  }
}

private struct CatalogNavigationBarModifier: ViewModifier {
  let title: String
  @Environment(\.composerLayoutStyle) private var style
  @Environment(\.horizontalSizeClass) private var sizeClass

  func body(content: Content) -> some View {
    #if os(macOS)
      // A bar, as the system's: content scrolls under it with the soft scroll edge effect.
      content.safeAreaBar(edge: .top, spacing: 0) {
        if style == .touch {
          CatalogNavigationBar(title: title, isCompact: sizeClass == .compact)
        }
      }
      .scrollEdgeEffectStyle(.soft, for: .top)
    #else
      content
    #endif
  }
}

/// A touch screen's inline navigation bar, drawn in place for Mac captures: the back or sidebar
/// button, the title, and the screen's actions, as glass circles over the content.
struct CatalogNavigationBar: View {
  let title: String
  let isCompact: Bool

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      circle(isCompact ? "chevron.backward" : "sidebar.left")
      Spacer(minLength: 0)
      Text(title)
        .font(.headline)
        .lineLimit(1)
      Spacer(minLength: 0)
      if !isCompact { circle("sidebar.right") }
      circle("ellipsis")
    }
    .padding(.horizontal, Theme.Spacing.large)
    .frame(height: 52)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
  }

  private func circle(_ symbol: String) -> some View {
    Image(systemName: symbol)
      .font(.system(size: 17, weight: .medium))
      .frame(width: 44, height: 44)
      .glassSurface(in: Circle())
      .accessibilityHidden(true)
  }
}

extension PlaygroundModel {
  /// The title a navigation bar shows for the model's destination.
  var navigationTitle: String {
    switch selection {
    case .session: conversation.header.title
    case .inbox: "Inbox"
    case .canvas: "Canvas"
    case .newSession, nil: ""
    }
  }
}
