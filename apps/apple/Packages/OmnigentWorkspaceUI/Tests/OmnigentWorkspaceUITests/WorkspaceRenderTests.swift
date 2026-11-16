#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// Renders each workspace surface in light and dark through a real `NSHostingView` (lists,
  /// pickers and text fields draw as in the app, unlike `ImageRenderer`), once it draws the same
  /// on two passes in a row. Each render must be the requested size and not blank, and dark must
  /// be darker than light. With `OMNIGENT_WORKSPACE_RENDER_DIR` set, images are written as
  /// `ws-<surface>-<scheme>.png`.
  @Suite("Workspace rendering", .serialized)
  struct WorkspaceRenderTests {
    nonisolated struct Surface: CustomTestStringConvertible, Sendable {
      let name: String
      let size: CGSize
      var compact = false
      let make: @MainActor @Sendable () async -> AnyView

      var testDescription: String { name }
    }

    nonisolated static let surfaces: [Surface] = [
      Surface(name: "browser-diff", size: CGSize(width: 1_280, height: 760)) {
        let model = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
        await WorkspaceGallery.prepare(model)
        return AnyView(WorkspaceBrowserView(model: model))
      },
      Surface(name: "browser-file", size: CGSize(width: 1_280, height: 760)) {
        let model = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
        await WorkspaceGallery.prepare(model.tree)
        model.search.query.query = "fixture needle"
        await model.search.search()
        model.tab = .search
        await model.open(.file(path: "src/lib.rs", line: 7))
        return AnyView(WorkspaceBrowserView(model: model))
      },
      Surface(name: "browser-compact", size: CGSize(width: 390, height: 760), compact: true) {
        let model = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
        await WorkspaceGallery.prepare(model.tree)
        return AnyView(WorkspaceBrowserView(model: model))
      },
      Surface(name: "tree", size: CGSize(width: 320, height: 520)) {
        let source = SampleWorkspaceDataSource(pageSize: 6)
        let tree = FileTreeModel(source: source)
        await WorkspaceGallery.prepare(tree)
        return AnyView(FileTreeView(model: tree, source: source, actions: .none))
      },
      Surface(name: "viewer-text", size: CGSize(width: 760, height: 520)) {
        AnyView(
          FileViewerView(
            file: WorkspaceSamples.libFile, line: 7, source: SampleWorkspaceDataSource()))
      },
      Surface(name: "viewer-clipped", size: CGSize(width: 760, height: 320)) {
        AnyView(
          FileViewerView(file: WorkspaceSamples.generatedFile, source: SampleWorkspaceDataSource()))
      },
      Surface(name: "viewer-image", size: CGSize(width: 520, height: 400)) {
        AnyView(
          FileViewerView(file: WorkspaceSamples.logoFile, source: SampleWorkspaceDataSource()))
      },
      Surface(name: "search", size: CGSize(width: 360, height: 560)) {
        let model = WorkspaceSamples.searchedModel()
        model.showsFilters = true
        model.query.include = "src/**, *.md"
        return AnyView(
          ContentSearchPanel(
            model: model, source: SampleWorkspaceDataSource(), actions: .none, onOpen: { _ in }))
      },
      Surface(name: "changes", size: CGSize(width: 340, height: 300)) {
        let model = ChangesModel(source: SampleWorkspaceDataSource())
        await model.reload()
        model.selection = "src/lib.rs"
        return AnyView(
          ChangedFilesList(model: model, source: SampleWorkspaceDataSource(), actions: .none) { _ in
          })
      },
      Surface(name: "diff-split", size: CGSize(width: 1_100, height: 520)) {
        AnyView(DiffViewerView(diff: WorkspaceSamples.libDiff, source: SampleWorkspaceDataSource()))
      },
      Surface(name: "diff-unified", size: CGSize(width: 760, height: 520)) {
        AnyView(DiffViewerView(diff: WorkspaceSamples.libDiff, source: SampleWorkspaceDataSource()))
      },
      Surface(name: "diff-too-large", size: CGSize(width: 760, height: 300)) {
        AnyView(
          DiffViewerView(diff: WorkspaceSamples.tooLargeDiff, source: SampleWorkspaceDataSource()))
      },
      Surface(name: "gallery", size: CGSize(width: 1_280, height: 800)) {
        AnyView(WorkspaceGalleryView())
      },
    ]

    @Test("renders in light and dark", arguments: surfaces)
    func render(surface: Surface) async throws {
      var luminance: [ColorScheme: Double] = [:]
      for scheme in [ColorScheme.light, .dark] {
        let view = await surface.make()
        let (image, pixels) = try Renderer.render(
          view, size: surface.size, scheme: scheme, compact: surface.compact)
        #expect(CGFloat(pixels.width) >= surface.size.width)
        #expect(CGFloat(pixels.height) >= surface.size.height)
        #expect(Renderer.inkCoverage(pixels) > 0.01, "\(surface.name) \(scheme) looks blank")
        luminance[scheme] = Renderer.averageLuminance(pixels)
        try Renderer.write(image, name: "ws-\(surface.name)-\(scheme == .light ? "light" : "dark")")
      }
      #expect((luminance[.light] ?? 0) > (luminance[.dark] ?? 1), "\(surface.name): dark is darker")
    }
  }

  enum Renderer {
    enum Failure: Error {
      case bitmapUnavailable
      case encodingFailed
    }

    /// How many layout and drawing passes a render may take to draw the same twice in a row.
    static let maxPasses = 12

    /// The view drawn in a window of `size`, once two passes a moment apart draw the same.
    static func render(
      _ view: AnyView, size: CGSize, scheme: ColorScheme, compact: Bool
    ) throws -> (NSBitmapImageRep, Pixels) {
      _ = NSApplication.shared
      let content =
        view
        .environment(\.colorScheme, scheme)
        .environment(\.horizontalSizeClass, compact ? .compact : .regular)
        .environment(\.controlActiveState, .key)
        .frame(width: size.width, height: size.height)
        .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.985))
      let host = NSHostingView(rootView: content)
      host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      let window = NSWindow(
        contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
        backing: .buffered, defer: false)
      window.appearance = host.appearance
      window.contentView = host
      host.frame = CGRect(origin: .zero, size: size)
      defer { window.orderOut(nil) }
      var drawn: (NSBitmapImageRep, Pixels)?
      for _ in 0..<maxPasses {
        host.layoutSubtreeIfNeeded()
        MainLoop.settle(limit: 0.03, windows: [window])
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
          throw Failure.bitmapUnavailable
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let pixels = try Pixels(bitmap)
        if pixels == drawn?.1 { break }
        drawn = (bitmap, pixels)
      }
      guard let drawn else { throw Failure.bitmapUnavailable }
      return drawn
    }

    static func write(_ image: NSBitmapImageRep, name: String) throws {
      guard let directory = ProcessInfo.processInfo.environment["OMNIGENT_WORKSPACE_RENDER_DIR"]
      else { return }
      let url = URL(filePath: directory, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      guard let data = image.representation(using: .png, properties: [:]) else {
        throw Failure.encodingFailed
      }
      try data.write(to: url.appending(path: "\(name).png"))
    }

    static func averageLuminance(_ pixels: Pixels) -> Double {
      var total = 0.0
      var samples = 0
      for row in stride(from: 0, to: pixels.height, by: 8) {
        for column in stride(from: 0, to: pixels.width, by: 8) {
          let color = pixels.color(column: column, row: row)
          total += 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
          samples += 1
        }
      }
      return samples == 0 ? 0 : total / Double(samples)
    }

    static func inkCoverage(_ pixels: Pixels) -> Double {
      var counts: [UInt32: Int] = [:]
      var samples = 0
      for row in stride(from: 0, to: pixels.height, by: 4) {
        for column in stride(from: 0, to: pixels.width, by: 4) {
          let color = pixels.color(column: column, row: row)
          let key =
            UInt32(color.red * 31) << 10 | UInt32(color.green * 31) << 5 | UInt32(color.blue * 31)
          counts[key, default: 0] += 1
          samples += 1
        }
      }
      guard samples > 0, let background = counts.values.max() else { return 0 }
      return Double(samples - background) / Double(samples)
    }
  }

  /// A render's pixels in 8-bit device RGB, rows from the top, read once instead of a color
  /// object per sample.
  struct Pixels: Equatable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    init(_ image: NSBitmapImageRep) throws {
      width = image.pixelsWide
      height = image.pixelsHigh
      let alpha = CGImageAlphaInfo.premultipliedLast.rawValue
      guard let source = image.cgImage,
        let context = unsafe CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha)
      else { throw Renderer.Failure.bitmapUnavailable }
      context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
      guard let drawn = context.makeImage(), let data = drawn.dataProvider?.data as Data? else {
        throw Renderer.Failure.bitmapUnavailable
      }
      bytesPerRow = drawn.bytesPerRow
      bytes = [UInt8](data)
    }

    /// A pixel's red, green and blue, from 0 to 1.
    struct Color {
      let red: Double
      let green: Double
      let blue: Double
    }

    /// The pixel in `column` from the left and `row` from the top.
    func color(column: Int, row: Int) -> Color {
      let offset = row * bytesPerRow + column * 4
      return Color(
        red: Double(bytes[offset]) / 255, green: Double(bytes[offset + 1]) / 255,
        blue: Double(bytes[offset + 2]) / 255)
    }
  }
#endif
