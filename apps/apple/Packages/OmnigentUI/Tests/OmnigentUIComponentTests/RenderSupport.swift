#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import SwiftUI

  @testable import OmnigentUIComponents

  /// Renders SwiftUI views offscreen through a real `NSHostingView` in a borderless window, so
  /// AppKit-backed controls (lists, text fields, menus) draw as they do in the app, which
  /// `ImageRenderer` does not do.
  enum RenderSupport {
    struct Rendered {
      let image: NSBitmapImageRep
      var size: CGSize { CGSize(width: image.pixelsWide, height: image.pixelsHigh) }
    }

    enum RenderError: Error, CustomStringConvertible {
      case bitmapUnavailable
      case encodingFailed

      var description: String {
        switch self {
        case .bitmapUnavailable: "The hosting view could not provide a bitmap."
        case .encodingFailed: "The bitmap could not be encoded as PNG."
        }
      }
    }

    /// The directory PNGs are written to, from `OMNIGENT_UI_RENDER_DIR`; `nil` renders in memory.
    static var outputDirectory: URL? {
      ProcessInfo.processInfo.environment["OMNIGENT_UI_RENDER_DIR"].map {
        URL(filePath: $0, directoryHint: .isDirectory)
      }
    }

    static func render(
      _ view: some View, width: CGFloat, height: CGFloat? = nil, scheme: ColorScheme,
      layout: LayoutWidth, increasedContrast: Bool = false
    ) throws -> Rendered {
      _ = NSApplication.shared
      let content =
        view
        .environment(\.layoutWidth, layout)
        .environment(\.horizontalSizeClass, layout == .compact ? .compact : .regular)
        .environment(\.colorScheme, scheme)
        .environment(\.controlActiveState, .key)
        .environment(\.flattensGlass, true)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: height == nil)
        .frame(height: height)
        .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.985))
      let host = NSHostingView(rootView: content)
      let appearance: NSAppearance.Name =
        increasedContrast
        ? (scheme == .dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
        : (scheme == .dark ? .darkAqua : .aqua)
      host.appearance = NSAppearance(named: appearance)
      let fitting = host.fittingSize
      let size = CGSize(width: width, height: height ?? max(fitting.height, 40))
      let window = NSWindow(
        contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
        backing: .buffered, defer: false)
      window.appearance = host.appearance
      window.contentView = host
      host.frame = CGRect(origin: .zero, size: size)
      host.layoutSubtreeIfNeeded()
      MainLoop.settle(limit: 0.15, windows: [window])
      host.layoutSubtreeIfNeeded()
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw RenderError.bitmapUnavailable
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      window.orderOut(nil)
      return Rendered(image: bitmap)
    }

    /// Writes `rendered` as `<name>.png` when an output directory is configured.
    static func write(_ rendered: Rendered, name: String) throws {
      guard let directory = outputDirectory else { return }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      guard let data = rendered.image.representation(using: .png, properties: [:]) else {
        throw RenderError.encodingFailed
      }
      try data.write(to: directory.appending(path: "\(name).png"))
    }

    /// Mean luminance (0 to 1) over a sample grid.
    static func averageLuminance(_ rendered: Rendered) -> Double {
      guard let pixels = Pixels(rendered.image) else { return 0 }
      var total = 0.0
      var samples = 0
      for row in stride(from: 0, to: pixels.height, by: 8) {
        for column in stride(from: 0, to: pixels.width, by: 8) {
          let color = pixels.color(column, row)
          total += 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
          samples += 1
        }
      }
      return samples == 0 ? 0 : total / Double(samples)
    }

    /// Whether any pixel is strongly colored in `hex`'s hue. Hues survive the display's color
    /// matching, which shifts exact values.
    static func shows(_ hex: UInt32, in rendered: Rendered) -> Bool {
      guard let pixels = Pixels(rendered.image) else { return false }
      let wanted = NSColor(Color(hex: hex)).usingColorSpace(.deviceRGB)?.hueComponent ?? 0
      for row in 0..<pixels.height {
        for column in 0..<pixels.width {
          let color = Pixels.hsb(pixels.color(column, row))
          guard color.saturation > 0.4, color.brightness > 0.4 else { continue }
          let distance = abs(color.hue - wanted)
          if min(distance, 1 - distance) < 0.05 { return true }
        }
      }
      return false
    }

    /// What an offscreen window's view draws now.
    static func capture(_ host: NSView) throws -> Rendered {
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw RenderError.bitmapUnavailable
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      return Rendered(image: bitmap)
    }

    /// The fraction of pixels that differ from the most common color: a cheap "something
    /// rendered" check that catches blank or placeholder output.
    static func inkCoverage(_ rendered: Rendered) -> Double {
      guard let pixels = Pixels(rendered.image) else { return 0 }
      var counts: [UInt32: Int] = [:]
      let step = 4
      var samples = 0
      for row in stride(from: 0, to: pixels.height, by: step) {
        for column in stride(from: 0, to: pixels.width, by: step) {
          counts[pixels.key(column, row), default: 0] += 1
          samples += 1
        }
      }
      guard samples > 0, let background = counts.values.max() else { return 0 }
      return Double(samples - background) / Double(samples)
    }

    /// How wide, in points, the drawing spans: from the first column with a pixel off the most
    /// common color to the last. Unlike ``inkCoverage(_:)``'s sparse grid, it sees a mark of a
    /// few pixels at any backing scale, wherever the text beside it lands on the pixel grid.
    static func inkedWidth(_ rendered: Rendered) -> CGFloat {
      let image = rendered.image
      guard let pixels = Pixels(image) else { return 0 }
      var counts: [UInt32: Int] = [:]
      for row in stride(from: 0, to: pixels.height, by: 2) {
        for column in stride(from: 0, to: pixels.width, by: 2) {
          counts[pixels.key(column, row), default: 0] += 1
        }
      }
      guard let background = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
      let inked = { (column: Int) in
        (0..<pixels.height).contains { row in pixels.key(column, row) != background }
      }
      let columns = 0..<pixels.width
      guard let first = columns.first(where: inked), let last = columns.last(where: inked) else {
        return 0
      }
      let pointsPerPixel = image.size.width / CGFloat(image.pixelsWide)
      return CGFloat(last - first + 1) * pointsPerPixel
    }

    /// An image's pixels in 8-bit device RGB, converted once: reading an `NSColor` for each pixel
    /// took most of a render test's time.
    struct Pixels {
      let width: Int
      let height: Int
      /// Premultiplied RGBA, the top row first.
      private let bytes: [UInt8]

      init?(_ image: NSBitmapImageRep) {
        guard let picture = image.cgImage else { return nil }
        width = picture.width
        height = picture.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
          let info = CGImageAlphaInfo.premultipliedLast.rawValue
          guard
            let context = unsafe CGContext(
              data: raw.baseAddress, width: picture.width, height: picture.height,
              bitsPerComponent: 8, bytesPerRow: picture.width * 4,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
          else { return false }
          context.draw(
            picture, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
          return true
        }
        guard drew else { return nil }
        bytes = buffer
      }

      /// A pixel's color, from the top left, with its alpha taken out.
      func color(_ column: Int, _ row: Int) -> (red: Double, green: Double, blue: Double) {
        let index = (row * width + column) * 4
        let alpha = Double(bytes[index + 3])
        guard alpha > 0 else { return (0, 0, 0) }
        return (
          Double(bytes[index]) / alpha, Double(bytes[index + 1]) / alpha,
          Double(bytes[index + 2]) / alpha
        )
      }

      /// Hue, saturation and brightness from 0 to 1, as `NSColor` gives them.
      static func hsb(_ color: (red: Double, green: Double, blue: Double)) -> (
        hue: Double, saturation: Double, brightness: Double
      ) {
        let highest = max(color.red, color.green, color.blue)
        let spread = highest - min(color.red, color.green, color.blue)
        guard highest > 0, spread > 0 else { return (0, 0, highest) }
        let sector: Double =
          if highest == color.red {
            (color.green - color.blue) / spread
          } else if highest == color.green {
            2 + (color.blue - color.red) / spread
          } else {
            4 + (color.red - color.green) / spread
          }
        let hue = (sector / 6).truncatingRemainder(dividingBy: 1)
        return (hue < 0 ? hue + 1 : hue, spread / highest, highest)
      }

      /// A pixel's color in 5 bits a channel, so near-equal colors count as one.
      func key(_ column: Int, _ row: Int) -> UInt32 {
        let (red, green, blue) = color(column, row)
        return UInt32(min(red, 1) * 31) << 10 | UInt32(min(green, 1) * 31) << 5
          | UInt32(min(blue, 1) * 31)
      }
    }
  }
#endif
