import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The chevron beside the organization's first server: a prominent button as tall as the
/// landing's others, listing every organization server in a menu.
///
/// A macOS `Menu` draws a shorter, untinted pop-up button, so there the button opens the menu
/// below itself, as a pull-down does.
struct OrganizationServerMenu: View {
  let servers: [ManagedServerEntry]
  let join: (String) -> Void

  #if os(macOS)
    @State private var anchor = MenuAnchor()
  #endif

  var body: some View {
    trigger
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .help("Choose another organization server")
      .accessibilityLabel("Choose organization server")
      .accessibilityIdentifier("auth.choose-preset")
  }

  @ViewBuilder private var trigger: some View {
    #if os(macOS)
      Button {
        anchor.popUp(NSHostingMenu(rootView: items))
      } label: {
        chevron
      }
      .background(MenuAnchorView(anchor: anchor))
    #else
      Menu {
        items
      } label: {
        chevron
      }
    #endif
  }

  private var items: some View {
    ForEach(servers) { server in
      Button(ServerText.escaped(server.displayName, limit: 80)) { join(server.url) }
    }
  }

  /// Text, not a bare image: an image-only button gets a shorter bezel than its neighbors.
  private var chevron: some View {
    Text(Image(systemName: "chevron.down")).accessibilityHidden(true)
  }
}

#if os(macOS)
  /// The view a menu opens below.
  final class MenuAnchor {
    weak var view: NSView?

    /// Opens `menu` below the anchored view, left edges aligned.
    func popUp(_ menu: NSMenu) {
      // The anchor is the button's own background, so it is there whenever the button is.
      guard let view else { return }
      menu.popUp(positioning: nil, at: CGPoint(x: 0, y: view.bounds.maxY + 4), in: view)
    }
  }

  /// Puts a flipped view behind the button, so the menu's origin is its bottom edge.
  private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
      let view = FlippedView()
      anchor.view = view
      return view
    }

    func updateNSView(_ view: NSView, context: Context) {
      anchor.view = view
    }
  }

  private final class FlippedView: NSView {
    override var isFlipped: Bool { true }

    /// Clicks go through to the button in front.
    override func hitTest(_ point: CGPoint) -> NSView? { nil }
  }
#endif
