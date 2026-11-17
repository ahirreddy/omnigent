import CoreGraphics
import Foundation
import IOSurface
import Synchronization

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

/// How settled message text reaches the screen in the table transcript:
/// `omnigent:message-text-surface`. `raster` draws each run ahead, off the main actor, into a
/// bitmap a cell shows as layer contents (``MessageTextRaster``), with a live text view laid
/// over it only while the reader selects; anything else keeps a live TextKit view per run.
nonisolated enum MessageTextSurface: String, Sendable {
  case textKit = "textkit"
  case raster

  static let key = "omnigent:message-text-surface"

  /// The surface this launch's defaults choose.
  static let launchValue = Self(defaults: .standard)

  init(defaults: UserDefaults) {
    self = defaults.string(forKey: Self.key).flatMap(Self.init(rawValue:)) ?? .textKit
  }
}

/// A laid-out run's size: how tall it is, its top inset included, and how wide its widest line.
nonisolated struct MessageTextSize: Equatable, Sendable {
  var height: CGFloat
  var usedWidth: CGFloat
}

/// A link's rectangle on one line of a drawn run, in the run's text coordinates.
nonisolated struct MessageTextLinkArea: Equatable, Sendable {
  var rect: CGRect
  var url: URL
}

/// What a raster draws: a run's attributed text, the space above its first line and its links.
nonisolated struct MessageTextRun: @unchecked Sendable {
  var text: NSAttributedString
  var topInset: CGFloat
  /// Each link's range in `text` and where it goes.
  var links: [(range: NSRange, url: URL)]
}

/// The colors a drawn run fills its layers with, resolved for one appearance.
nonisolated struct MessageTextRasterStyle: @unchecked Sendable {
  var codeSurface: CGColor
  var codeHeader: CGColor
  var separator: CGColor
  var border: CGColor
  var quoteBar: CGColor
  var link: CGColor
  /// A code block's corner radius.
  var codeRadius: CGFloat
}

/// A run of message text laid out with TextKit 2 at one width and drawn into one bitmap at one
/// scale, off the main actor, with what a cell needs to show it without a text view: its size,
/// its links' rectangles and where its controls go. The bitmap holds the text and the layers
/// behind it (code block surfaces, rules, table rules, quote bars); it starts below the run's
/// top inset. It is an IOSurface, which a layer shows as its contents without the copy a
/// `CGImage` costs the main thread when the layer is committed.
nonisolated final class MessageTextRaster: @unchecked Sendable {
  let width: CGFloat
  let scale: CGFloat
  let size: MessageTextSize
  let topInset: CGFloat
  /// `nil` for a run with nothing to draw.
  let surface: IOSurface?
  let links: [MessageTextLinkArea]
  /// Each block's control (a code block's header, a table's menu), by block.
  let chromeFrames: [Int: CGRect]
  /// A table is wider than the run: only a live view, which scrolls it sideways, shows it.
  let overflows: Bool

  /// The bitmap's memory.
  var byteCount: Int { surface?.allocationSize ?? 0 }

  /// Draws `run` as `manager` lays it out (laying out what it has not yet).
  /// - Parameters:
  ///   - run: The run; its top inset stays outside the bitmap.
  ///   - manager: A TextKit 2 layout manager for the run's text, its container `width` wide.
  ///   - width: The width the run lays out at.
  ///   - scale: Pixels per point.
  ///   - style: The layers' colors.
  init(
    _ run: MessageTextRun, manager: NSTextLayoutManager, width: CGFloat, scale: CGFloat,
    style: MessageTextRasterStyle
  ) {
    self.width = width
    self.scale = scale
    topInset = run.topInset
    var collector = MessageTextLayerCollector(width: width)
    var fragments: [NSTextLayoutFragment] = []
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
      fragments.append(fragment)
      return true
    }
    let textHeight = max(height, collector.bottom)
    size = MessageTextSize(
      height: (textHeight + run.topInset).rounded(.up), usedWidth: usedWidth.rounded(.up))
    chromeFrames = collector.chromeFrames
    overflows = MessageTextBlockSpan.spans(in: run.text).values.contains {
      $0.overflows(width: width, wraps: true)
    }
    links = Self.linkAreas(run.links, in: manager)
    surface = Self.draw(
      fragments, shapes: collector.shapes, size: CGSize(width: width, height: textHeight),
      scale: scale, style: style)
  }

  /// Lays `run` out on a TextKit stack of its own `width` wide, then draws it.
  static func make(
    _ run: MessageTextRun, width: CGFloat, scale: CGFloat, style: MessageTextRasterStyle
  ) -> MessageTextRaster {
    let storage = NSTextContentStorage()
    let manager = NSTextLayoutManager()
    storage.addTextLayoutManager(manager)
    let container = NSTextContainer(size: CGSize(width: width, height: 10_000_000))
    container.lineFragmentPadding = 0
    manager.textContainer = container
    storage.textStorage?.setAttributedString(
      linksStyled(run.text, links: run.links, style: style))
    return MessageTextRaster(run, manager: manager, width: width, scale: scale, style: style)
  }

  /// `text` with each link drawn as the text views show one, in `style`'s link color and
  /// underlined, and no longer a link: TextKit would draw a link in its own default style.
  static func linksStyled(
    _ text: NSAttributedString, links: [(range: NSRange, url: URL)],
    style: MessageTextRasterStyle
  ) -> NSAttributedString {
    guard !links.isEmpty else { return text }
    #if canImport(UIKit)
      let color = UIColor(cgColor: style.link)
    #else
      let color = NSColor(cgColor: style.link) ?? .linkColor
    #endif
    let styled = NSMutableAttributedString(attributedString: text)
    for link in links {
      styled.removeAttribute(.link, range: link.range)
      styled.addAttributes(
        [.foregroundColor: color, .underlineStyle: NSUnderlineStyle.single.rawValue],
        range: link.range)
    }
    return styled
  }

  /// The link at `point`, in the run's text coordinates.
  func link(at point: CGPoint) -> URL? {
    links.first { $0.rect.contains(point) }?.url
  }

  private static func linkAreas(
    _ links: [(range: NSRange, url: URL)], in manager: NSTextLayoutManager
  ) -> [MessageTextLinkArea] {
    guard let content = manager.textContentManager else { return [] }
    var areas: [MessageTextLinkArea] = []
    for link in links {
      guard
        let start = content.location(
          content.documentRange.location, offsetBy: link.range.location),
        let end = content.location(start, offsetBy: link.range.length),
        let range = NSTextRange(location: start, end: end)
      else { continue }
      manager.enumerateTextSegments(in: range, type: .standard) { _, frame, _, _ in
        areas.append(MessageTextLinkArea(rect: frame, url: link.url))
        return true
      }
    }
    return areas
  }

  /// Premultiplied BGRA, as the layers' own backing stores are.
  private static let pixelFormat: UInt32 = 0x4247_5241

  /// The layers, then the text, into a bitmap with its origin at the top left.
  private static func draw(
    _ fragments: [NSTextLayoutFragment], shapes: [MessageTextShape], size: CGSize,
    scale: CGFloat, style: MessageTextRasterStyle
  ) -> IOSurface? {
    let pixelWidth = Int((size.width * scale).rounded(.up))
    let pixelHeight = Int((size.height * scale).rounded(.up))
    guard pixelWidth > 0, pixelHeight > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
      let surface = IOSurface(properties: [
        IOSurfacePropertyKey(rawValue: "IOSurfaceWidth"): pixelWidth,
        IOSurfacePropertyKey(rawValue: "IOSurfaceHeight"): pixelHeight,
        IOSurfacePropertyKey(rawValue: "IOSurfaceBytesPerElement"): 4,
        IOSurfacePropertyKey(rawValue: "IOSurfacePixelFormat"): pixelFormat,
      ])
    else { return nil }
    if let profile = space.copyICCData() as Data? {
      surface.setAttachment(profile, forKey: "IOSurfaceColorSpace")
    }
    _ = unsafe surface.lock(options: [], seed: nil)
    defer { _ = unsafe surface.unlock(options: [], seed: nil) }
    guard
      let context = unsafe CGContext(
        data: surface.baseAddress, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
        bytesPerRow: surface.bytesPerRow, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    context.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.scaleBy(x: scale, y: -scale)
    context.setShouldSmoothFonts(false)
    for shape in shapes { fill(shape, in: context, style: style) }
    #if os(macOS)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
      defer { NSGraphicsContext.restoreGraphicsState() }
    #else
      UIGraphicsPushContext(context)
      defer { UIGraphicsPopContext() }
    #endif
    for fragment in fragments {
      fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
    }
    context.flush()
    return surface
  }

  private static func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
    return path
  }

  private static func fill(
    _ shape: MessageTextShape, in context: CGContext, style: MessageTextRasterStyle
  ) {
    switch shape {
    case .codeBlock(let rect):
      let outline = roundedPath(rect, radius: style.codeRadius)
      context.saveGState()
      context.addPath(outline)
      context.clip()
      context.setFillColor(style.codeSurface)
      context.fill(rect)
      let header = MessageTextMetrics.codeHeaderHeight
      context.setFillColor(style.codeHeader)
      context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: header))
      context.setFillColor(style.separator)
      context.fill(CGRect(x: rect.minX, y: rect.minY + header, width: rect.width, height: 1))
      context.restoreGState()
      // A layer's border lies inside its bounds.
      let inset = rect.insetBy(dx: 0.5, dy: 0.5)
      context.addPath(roundedPath(inset, radius: style.codeRadius - 0.5))
      context.setStrokeColor(style.border)
      context.setLineWidth(1)
      context.strokePath()
    case .image(let image, let rect):
      // The context is flipped; an image draws right way up in a frame flipped back.
      context.saveGState()
      context.translateBy(x: rect.minX, y: rect.maxY)
      context.scaleBy(x: 1, y: -1)
      context.draw(image, in: CGRect(origin: .zero, size: rect.size))
      context.restoreGState()
    case .fill(let rect, let fill):
      switch fill {
      case .separator: context.setFillColor(style.separator)
      case .border: context.setFillColor(style.border)
      case .hover: context.setFillColor(style.codeHeader)
      case .quoteBar: context.setFillColor(style.quoteBar)
      }
      if case .quoteBar = fill {
        context.addPath(roundedPath(rect, radius: 1.5))
        context.fillPath()
      } else {
        context.fill(rect)
      }
    }
  }
}

/// Which run a raster draws: a document, by its serial, at a width and scale.
nonisolated struct MessageTextRasterKey: Hashable, Sendable {
  var document: UInt64
  var width: CGFloat
  var scale: CGFloat
}

/// Drawn runs, kept under a memory budget, least recently shown first out. Written off the main
/// actor as runs are drawn ahead, read on it as rows show.
nonisolated final class MessageTextRasters: Sendable {
  static let shared = MessageTextRasters(byteLimit: 256 << 20)

  private struct State {
    var entries: [MessageTextRasterKey: MessageTextRaster] = [:]
    /// Keys, least recently used first.
    var order: [MessageTextRasterKey] = []
    var bytes = 0
  }

  private let byteLimit: Int
  private let state = Mutex(State())

  init(byteLimit: Int) {
    self.byteLimit = byteLimit
  }

  /// The raster for `key`, now the most recently used.
  func raster(for key: MessageTextRasterKey) -> MessageTextRaster? {
    state.withLock { state in
      guard let raster = state.entries[key] else { return nil }
      if state.order.last != key {
        state.order.removeAll { $0 == key }
        state.order.append(key)
      }
      return raster
    }
  }

  func contains(_ key: MessageTextRasterKey) -> Bool {
    state.withLock { $0.entries[key] != nil }
  }

  /// Keeps `raster`, letting the least recently used go past the budget.
  func store(_ raster: MessageTextRaster, for key: MessageTextRasterKey) {
    state.withLock { state in
      if let old = state.entries[key] {
        state.bytes -= old.byteCount
        state.order.removeAll { $0 == key }
      }
      state.entries[key] = raster
      state.order.append(key)
      state.bytes += raster.byteCount
      while state.bytes > byteLimit, state.order.count > 1 {
        let oldest = state.order.removeFirst()
        state.bytes -= state.entries.removeValue(forKey: oldest)?.byteCount ?? 0
      }
    }
  }

  /// The memory the kept rasters take.
  var byteCount: Int { state.withLock { $0.bytes } }
}
