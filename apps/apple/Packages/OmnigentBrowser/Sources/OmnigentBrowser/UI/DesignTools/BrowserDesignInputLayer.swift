internal import CoreGraphics
internal import SwiftUI

/// What the tools' input layer reports, in its points from the top left.
struct BrowserDesignInputHandlers {
  var move: (CGPoint) -> Void = { _ in }
  var press: (CGPoint) -> Void = { _ in }
  var drag: (CGPoint) -> Void = { _ in }
  var release: (CGPoint) -> Void = { _ in }
  var escape: () -> Void = {}
  /// The layer scrolled the page under it.
  var scrolled: () -> Void = {}
  /// Apple Pencil's double tap where the system's setting is to switch to the eraser.
  var undo: () -> Void = {}
  /// Apple Pencil's double tap where the system's setting is to switch to the previous tool.
  var previousTool: () -> Void = {}
}

/// The page's views the input layer works with.
struct BrowserDesignPageViews {
  /// The page's view, which the wheel or two fingers scroll.
  let view: BrowserPlatformView?
  /// The view that takes typing for the page.
  let keyboard: BrowserPlatformView?
}

/// The transparent layer over the page that takes the pointer, touches and keys while a tool is
/// open, so the page sees none of them: AppKit's on the Mac, UIKit's on iPhone and iPad.
struct BrowserDesignInputLayer: View {
  let handlers: BrowserDesignInputHandlers
  /// The pointer aims (a crosshair), rather than the arrow of a tool that waits.
  let aims: Bool
  /// The wheel, or two fingers, scroll the page.
  let scrolls: Bool
  /// One finger draws; it scrolls instead where the system prefers Apple Pencil for drawing.
  var draws = false
  let page: BrowserDesignPageViews

  var body: some View {
    #if os(macOS)
      BrowserDesignInput(
        handlers: handlers, cursor: aims ? .crosshair : .arrow, scrolls: scrolls,
        page: page.view, pageKeyboard: page.keyboard)
    #else
      BrowserDesignTouchInput(handlers: handlers, scrolls: scrolls, draws: draws, page: page.view)
    #endif
  }
}
