#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  extension RenderSupport {
    /// The view's pixels, for telling two states apart.
    static func picture(_ view: some View, width: CGFloat, height: CGFloat) throws -> Data {
      let rendered = try render(
        view, width: width, height: height, scheme: .light, layout: .regular)
      return try #require(rendered.image.tiffRepresentation)
    }
  }

  extension OffscreenWindow {
    /// The middle of the tab at this distance along an unpinned strip with equal tabs.
    func tabCenter(index: Int, width: CGFloat, leading: CGFloat = 4) -> CGPoint {
      CGPoint(x: leading + width * (CGFloat(index) + 0.5), y: host.bounds.midY)
    }
  }
#endif
