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
      let image = rendered.image
      var total = 0.0
      var samples = 0
      for row in stride(from: 0, to: image.pixelsHigh, by: 8) {
        for column in stride(from: 0, to: image.pixelsWide, by: 8) {
          guard let color = image.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else {
            continue
          }
          total +=
            0.2126 * color.redComponent + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
          samples += 1
        }
      }
      return samples == 0 ? 0 : total / Double(samples)
    }

    /// Whether any pixel is strongly colored in `hex`'s hue. Hues survive the display's color
    /// matching, which shifts exact values.
    static func shows(_ hex: UInt32, in rendered: Rendered) -> Bool {
      let image = rendered.image
      let wanted = NSColor(Color(hex: hex)).usingColorSpace(.deviceRGB)?.hueComponent ?? 0
      for row in 0..<image.pixelsHigh {
        for column in 0..<image.pixelsWide {
          guard let color = image.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB),
            color.saturationComponent > 0.4, color.brightnessComponent > 0.4
          else { continue }
          let distance = abs(color.hueComponent - wanted)
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
      let image = rendered.image
      var counts: [UInt32: Int] = [:]
      let step = 4
      var samples = 0
      for row in stride(from: 0, to: image.pixelsHigh, by: step) {
        for column in stride(from: 0, to: image.pixelsWide, by: step) {
          guard let key = colorKey(image, column, row) else { continue }
          counts[key, default: 0] += 1
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
      var counts: [UInt32: Int] = [:]
      for row in stride(from: 0, to: image.pixelsHigh, by: 2) {
        for column in stride(from: 0, to: image.pixelsWide, by: 2) {
          if let key = colorKey(image, column, row) { counts[key, default: 0] += 1 }
        }
      }
      guard let background = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
      let inked = { (column: Int) in
        (0..<image.pixelsHigh).contains { row in
          colorKey(image, column, row).map { $0 != background } ?? false
        }
      }
      let columns = 0..<image.pixelsWide
      guard let first = columns.first(where: inked), let last = columns.last(where: inked) else {
        return 0
      }
      let pointsPerPixel = image.size.width / CGFloat(image.pixelsWide)
      return CGFloat(last - first + 1) * pointsPerPixel
    }

    /// A pixel's color in 5 bits a channel, so near-equal colors count as one.
    private static func colorKey(_ image: NSBitmapImageRep, _ column: Int, _ row: Int) -> UInt32? {
      guard let color = image.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else {
        return nil
      }
      return UInt32(color.redComponent * 31) << 10 | UInt32(color.greenComponent * 31) << 5
        | UInt32(color.blueComponent * 31)
    }
  }
#endif
