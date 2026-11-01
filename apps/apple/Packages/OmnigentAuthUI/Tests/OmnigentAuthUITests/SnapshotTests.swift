#if os(macOS)
  import AppKit
  import CoreGraphics
  import Foundation
  import ImageIO
  import SwiftUI
  import Testing
  import UniformTypeIdentifiers

  @testable import OmnigentAuthUI

  /// Renders every sample in light and dark, at a desktop card width and a compact (iPhone)
  /// width. With `OMNIGENT_AUTH_RENDER_DIR` set, the images are written there as
  /// `auth-<sample>-<mac|compact>-<light|dark>.png`; otherwise they are checked in memory only.
  ///
  /// The screens render through an `NSHostingView` in an offscreen window. `ImageRenderer` draws
  /// SwiftUI's own shapes and text but replaces AppKit-backed controls (text fields, secure
  /// fields, menus) with a placeholder, so it is used only for the pure-SwiftUI account chip,
  /// where it is checked against the hosting-view path.
  @Suite(.serialized)
  struct SnapshotTests {
    enum Width: String, CaseIterable {
      case mac
      case compact

      var points: CGFloat {
        switch self {
        case .mac: 560
        case .compact: 390
        }
      }

      var sizeClass: UserInterfaceSizeClass {
        switch self {
        case .mac: .regular
        case .compact: .compact
        }
      }
    }

    enum RenderError: Error, CustomStringConvertible {
      case noImage(String)
      case encodingFailed(String)

      var description: String {
        switch self {
        case .noImage(let name): "No image was rendered for \(name)."
        case .encodingFailed(let name): "Could not encode \(name) as PNG."
        }
      }
    }

    static var outputDirectory: URL? {
      ProcessInfo.processInfo.environment["OMNIGENT_AUTH_RENDER_DIR"].map {
        URL(filePath: $0, directoryHint: .isDirectory)
      }
    }

    @Test(arguments: AuthSamples.all.map(\.id))
    func rendersSample(_ id: String) throws {
      let sample = try #require(AuthSamples.sample(id))
      for width in Width.allCases {
        for scheme in [ColorScheme.light, .dark] {
          let view = AuthFlowView(
            state: sample.state, actions: .inert, validator: .preview, presentation: .sheet)
          let name = "auth-\(id)-\(width.rawValue)-\(scheme == .dark ? "dark" : "light")"
          let image = try Self.hostRender(view, width: width, scheme: scheme)
          try Self.write(image, name: name)
          #expect(image.width >= Int(width.points), "\(name) is narrower than its frame")
          #expect(image.height > 200, "\(name) rendered almost nothing")
          #expect(Self.inkCoverage(image) > 0.02, "\(name) looks blank")
        }
      }
    }

    @Test func rendersAccountChipWithImageRenderer() throws {
      for scheme in [ColorScheme.light, .dark] {
        let chip = AccountChipLabel(account: AuthSamples.account)
          .padding(16)
          .background(Self.background(scheme))
          .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: chip)
        renderer.scale = 2
        let name = "auth-account-chip-\(scheme == .dark ? "dark" : "light")"
        guard let image = renderer.cgImage else { throw RenderError.noImage(name) }
        try Self.write(image, name: name)
        #expect(image.width > 200)
        #expect(Self.inkCoverage(image) > 0.05)
      }
    }

    /// The gallery hosts every sample in a split view. Offscreen, AppKit leaves the sidebar list
    /// undrawn, so this checks that it lays out rather than writing a misleading PNG.
    @Test func galleryLaysOut() {
      _ = NSApplication.shared
      let host = NSHostingView(rootView: AuthGalleryView().frame(width: 900, height: 640))
      host.frame = CGRect(x: 0, y: 0, width: 900, height: 640)
      host.layoutSubtreeIfNeeded()
      #expect(host.fittingSize.width > 0)
    }

    static func background(_ scheme: ColorScheme) -> Color {
      scheme == .dark ? Color(white: 0.13) : Color(white: 0.98)
    }

    /// Renders `view` through a real `NSHostingView`, so AppKit-backed controls draw.
    static func hostRender(
      _ view: some View, width: Width?, scheme: ColorScheme, height: CGFloat? = nil
    ) throws -> CGImage {
      _ = NSApplication.shared
      let content =
        view
        .frame(width: width?.points)
        .fixedSize(horizontal: width == nil, vertical: height == nil)
        .background(background(scheme))
        .environment(\.colorScheme, scheme)
        .environment(\.horizontalSizeClass, width?.sizeClass ?? .regular)
        // Render as the key window, so the default button shows its accent as it does in use.
        .environment(\.controlActiveState, .key)
      let host = NSHostingView(rootView: content)
      host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      let fitting = host.fittingSize
      let size = CGSize(
        width: width?.points ?? fitting.width, height: height ?? max(fitting.height, 40))
      let window = NSWindow(
        contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
        backing: .buffered, defer: false)
      window.appearance = host.appearance
      window.contentView = host
      host.frame = CGRect(origin: .zero, size: size)
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.1))
      host.layoutSubtreeIfNeeded()
      defer { window.orderOut(nil) }
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw RenderError.noImage("hosting view")
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let image = bitmap.cgImage else { throw RenderError.noImage("hosting view") }
      return image
    }

    static func write(_ image: CGImage, name: String) throws {
      guard let outputDirectory else { return }
      try FileManager.default.createDirectory(
        at: outputDirectory, withIntermediateDirectories: true)
      let url = outputDirectory.appending(path: "\(name).png")
      guard
        let destination = CGImageDestinationCreateWithURL(
          url as CFURL, UTType.png.identifier as CFString, 1, nil)
      else { throw RenderError.encodingFailed(name) }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else {
        throw RenderError.encodingFailed(name)
      }
    }

    /// The fraction of sampled pixels that differ from the most common color.
    static func inkCoverage(_ image: CGImage) -> Double {
      let bitmap = NSBitmapImageRep(cgImage: image)
      var counts: [UInt32: Int] = [:]
      var samples = 0
      for row in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
        for column in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
          guard let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else {
            continue
          }
          let key =
            UInt32(color.redComponent * 31) << 10 | UInt32(color.greenComponent * 31) << 5
            | UInt32(color.blueComponent * 31)
          counts[key, default: 0] += 1
          samples += 1
        }
      }
      guard samples > 0, let background = counts.values.max() else { return 0 }
      return Double(samples - background) / Double(samples)
    }
  }
#endif
