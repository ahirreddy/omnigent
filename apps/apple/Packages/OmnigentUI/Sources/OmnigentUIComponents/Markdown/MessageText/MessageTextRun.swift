import CoreGraphics
import Foundation
import Synchronization

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

nonisolated extension MessageTextSize {
  /// The size of the text `manager` lays out `width` wide, laid out now where it isn't yet: as
  /// a text view or a raster measures it, its top inset included.
  static func measure(_ manager: NSTextLayoutManager, width: CGFloat, topInset: CGFloat) -> Self {
    var collector = MessageTextLayerCollector(width: width)
    var height: CGFloat = 0
    var usedWidth: CGFloat = 0
    _ = manager.enumerateTextLayoutFragments(
      from: manager.documentRange.location, options: [.ensuresLayout]
    ) { fragment in
      let frame = fragment.layoutFragmentFrame
      height = max(height, frame.maxY)
      for line in fragment.textLineFragments {
        usedWidth = max(usedWidth, frame.minX + line.typographicBounds.maxX)
      }
      collector.add(fragment)
      return true
    }
    return Self(
      height: (max(height, collector.bottom) + topInset).rounded(.up),
      usedWidth: usedWidth.rounded(.up))
  }
}

/// Laid-out runs' sizes, by document and width, from wherever a run was laid out (ahead, drawn,
/// or measured on the main actor): a row far from view is measured from them, with no text
/// view. Written off the main actor, read on it.
nonisolated final class MessageTextSizes: Sendable {
  static let shared = MessageTextSizes(limit: 4096)

  private struct Key: Hashable {
    var document: UInt64
    var width: CGFloat
  }

  private let entries: Mutex<BoundedCache<Key, MessageTextSize>>

  init(limit: Int) {
    entries = Mutex(BoundedCache(limit: limit))
  }

  /// The size `document` laid out at `width`, if it was.
  func size(document: UInt64, width: CGFloat) -> MessageTextSize? {
    entries.withLock { $0.cached(Key(document: document, width: width)) }
  }

  func store(_ size: MessageTextSize, document: UInt64, width: CGFloat) {
    entries.withLock { $0.store(size, for: Key(document: document, width: width)) }
  }
}
