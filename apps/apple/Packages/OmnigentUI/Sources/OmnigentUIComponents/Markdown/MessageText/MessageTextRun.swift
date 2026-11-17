import CoreGraphics
import Foundation

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

/// What a raster draws: a run's attributed text, the space above its first line, its links
/// and which kind of controls each block has.
nonisolated struct MessageTextRun: @unchecked Sendable {
  var text: NSAttributedString
  var topInset: CGFloat
  /// Each link's range in `text` and where it goes.
  var links: [(range: NSRange, url: URL)]
  /// Each block's controls, by block.
  var chrome: [Int: MessageTextRunChrome] = [:]
}

/// The controls a block of a drawn run has: a code block's header or a table's row.
nonisolated enum MessageTextRunChrome: Hashable, Sendable {
  case code
  case table
}

nonisolated extension MessageTextDocument {
  /// What a raster draws of it.
  var run: MessageTextRun {
    MessageTextRun(
      text: text, topInset: topInset, links: links,
      chrome: chrome.mapValues {
        switch $0 {
        case .code: .code
        case .table: .table
        }
      })
  }
}

/// A block's controls as they look at rest, drawn into a run in their place: the controls
/// themselves are made only once the pointer reaches them.
nonisolated struct MessageTextChromeStamp: @unchecked Sendable {
  var image: CGImage
  /// Its size in points.
  var size: CGSize
  /// It sits at its frame's trailing edge (a code block's header), else at its leading one.
  var isTrailing: Bool

  /// Where it goes in a block's control frame.
  func frame(in chrome: CGRect) -> CGRect {
    CGRect(
      x: isTrailing ? chrome.maxX - size.width : chrome.minX, y: chrome.minY,
      width: size.width, height: size.height)
  }
}

/// The colors a drawn run fills its layers with, resolved for one appearance, and its blocks'
/// controls at rest, drawn at the run's scale.
nonisolated struct MessageTextRasterStyle: @unchecked Sendable {
  var codeSurface: CGColor
  var codeHeader: CGColor
  var separator: CGColor
  var border: CGColor
  var quoteBar: CGColor
  var link: CGColor
  /// A code block's corner radius.
  var codeRadius: CGFloat
  /// A code block's header controls; `nil` leaves them to views.
  var codeChrome: MessageTextChromeStamp?
  /// A table's controls row; `nil` leaves it to a view.
  var tableChrome: MessageTextChromeStamp?

  /// The stamp drawn for `chrome`.
  func stamp(for chrome: MessageTextRunChrome) -> MessageTextChromeStamp? {
    switch chrome {
    case .code: codeChrome
    case .table: tableChrome
    }
  }
}
