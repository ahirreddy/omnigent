import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The size one render of an entry takes, and whether its height follows its content. Whole
/// pages take their screen, or the whole drawn device when framed.
struct CatalogLayout: Hashable {
  let width: CGFloat
  /// `nil` grows to fit the content.
  let height: CGFloat?
  let screen: CatalogScreen
  /// A whole page on a screen, rather than a component.
  let isPage: Bool
  /// The page is drawn in its device frame.
  let isFramed: Bool

  init(canvas: CatalogCanvas, screen: CatalogScreen, framed: Bool = true) {
    self.screen = screen
    isPage = !canvas.devices.isEmpty
    isFramed = isPage && framed && screen.device != .mac
    switch canvas {
    case .column(let width):
      self.width = screen.layoutWidth == .compact ? min(width, screen.size.width) : width
      height = nil
    case .fixed(let width, let height):
      self.width = width
      self.height = height
    case .device:
      let size = isFramed ? screen.framedSize : screen.size
      width = size.width
      height = size.height
    }
  }

  /// The scale that fits `columns` renders side by side in `available`, for whole pages; 1 for
  /// renders whose height follows their content.
  func fitScale(in available: CGSize, columns: Int) -> CGFloat {
    guard let height else { return 1 }
    let count = CGFloat(max(columns, 1))
    let gutter = Theme.Spacing.extraLarge
    let byWidth = (available.width - gutter * (count + 1)) / (width * count)
    // The frame's label and padding sit above the page.
    let byHeight = (available.height - gutter * 2 - 30) / height
    return max(0.2, min(1, byWidth, byHeight))
  }
}

extension View {
  /// The root every catalog render shares, live and exported: the traits, the size and the
  /// theme canvas behind the content.
  func catalogRoot(_ traits: CatalogTraits, layout: CatalogLayout) -> some View {
    Group {
      if layout.isPage {
        CatalogDeviceView(screen: layout.screen, isFramed: layout.isFramed) { self }
      } else {
        frame(width: layout.width)
          .frame(height: layout.height)
          .fixedSize(horizontal: false, vertical: layout.height == nil)
          .themeCanvas()
      }
    }
    .catalogTraits(traits)
    #if os(macOS)
      .environment(\.controlActiveState, .key)
    #endif
  }
}

/// One live render: the state's view made once, under `traits`, at `layout`.
struct CatalogCanvasView: View {
  let state: CatalogState
  let context: CatalogContext
  let traits: CatalogTraits
  let layout: CatalogLayout
  @State private var content: AnyView?
  @State private var measuredHeight: CGFloat?

  var body: some View {
    Group {
      if let content {
        CatalogHostedContent(
          content: content, traits: traits, layout: layout, measuredHeight: $measuredHeight
        )
        .frame(width: layout.width, height: layout.height ?? measuredHeight ?? 200)
      } else {
        Color.clear.frame(width: layout.width, height: layout.height ?? 200)
      }
    }
    .onAppear {
      if content == nil { content = state.make(context) }
    }
  }
}

#if os(macOS)
  /// Hosts a render in its own `NSHostingView`, so its appearance (light, dark, increased
  /// contrast) reaches AppKit-backed lists, materials and controls the way a window's does. The
  /// host bridges nothing to the gallery window, so a page's toolbar does not draw.
  struct CatalogHostedContent: NSViewRepresentable {
    let content: AnyView
    let traits: CatalogTraits
    let layout: CatalogLayout
    /// The content's own height, for layouts whose height follows it.
    @Binding var measuredHeight: CGFloat?

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
      let host = NSHostingView(rootView: root)
      host.sceneBridgingOptions = []
      // The canvas is sized from `measuredHeight`, not from the host's intrinsic size.
      host.sizingOptions = []
      host.appearance = CatalogAppearanceName.appearance(for: traits)
      return host
    }

    func updateNSView(_ host: NSHostingView<AnyView>, context: Context) {
      host.rootView = root
      host.appearance = CatalogAppearanceName.appearance(for: traits)
    }

    private var root: AnyView {
      let height = $measuredHeight
      return AnyView(
        content.catalogRoot(traits, layout: layout)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: { measured in
            if height.wrappedValue != measured { height.wrappedValue = measured }
          })
    }
  }

  enum CatalogAppearanceName {
    static func appearance(for traits: CatalogTraits) -> NSAppearance? {
      let name: NSAppearance.Name =
        switch (traits.scheme, traits.increaseContrast) {
        case (.dark, true): .accessibilityHighContrastDarkAqua
        case (.dark, false): .darkAqua
        case (_, true): .accessibilityHighContrastAqua
        default: .aqua
        }
      return NSAppearance(named: name)
    }
  }
#else
  /// A render under `traits` at `layout`.
  struct CatalogHostedContent: View {
    let content: AnyView
    let traits: CatalogTraits
    let layout: CatalogLayout
    /// The content's own height, for layouts whose height follows it.
    @Binding var measuredHeight: CGFloat?

    var body: some View {
      content.catalogRoot(traits, layout: layout)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: { measured in
          if measuredHeight != measured { measuredHeight = measured }
        }
    }
  }
#endif

/// A page labelled with its device and appearance: in its drawn frame, or outlined as a
/// window (the Mac, or with frames off).
struct CatalogPageFrame<Content: View>: View {
  let layout: CatalogLayout
  let label: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Label(label, systemImage: layout.screen.device.systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
      if layout.isFramed {
        content.shadow(color: .black.opacity(0.18), radius: 16, y: 6)
      } else {
        content
          .clipShape(layout.screen.displayShape)
          .overlay { layout.screen.displayShape.strokeBorder(.separator) }
          .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
      }
    }
  }
}

/// A component's outline: a hairline card, labelled with its appearance.
struct CatalogComponentFrame<Content: View>: View {
  let label: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      content
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            .strokeBorder(.separator)
        }
    }
  }
}
