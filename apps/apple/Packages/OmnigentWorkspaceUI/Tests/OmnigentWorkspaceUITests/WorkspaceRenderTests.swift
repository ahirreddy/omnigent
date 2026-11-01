#if os(macOS)
  import AppKit
  import Foundation
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// Renders each workspace surface in light and dark through a real `NSHostingView` (lists,
  /// pickers and text fields draw as in the app, unlike `ImageRenderer`). Each render must be
  /// the requested size and not blank, and dark must be darker than light. With
  /// `OMNIGENT_WORKSPACE_RENDER_DIR` set, images are written as `ws-<surface>-<scheme>.png`.
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
        let image = try Renderer.render(
          view, size: surface.size, scheme: scheme, compact: surface.compact)
        #expect(CGFloat(image.pixelsWide) >= surface.size.width)
        #expect(CGFloat(image.pixelsHigh) >= surface.size.height)
        #expect(Renderer.inkCoverage(image) > 0.01, "\(surface.name) \(scheme) looks blank")
        luminance[scheme] = Renderer.averageLuminance(image)
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

    static func render(
      _ view: AnyView, size: CGSize, scheme: ColorScheme, compact: Bool
    ) throws -> NSBitmapImageRep {
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
      for _ in 0..<3 {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
      }
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw Failure.bitmapUnavailable
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      window.orderOut(nil)
      return bitmap
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

    static func averageLuminance(_ image: NSBitmapImageRep) -> Double {
      var total = 0.0
      var samples = 0
      for row in stride(from: 0, to: image.pixelsHigh, by: 8) {
        for column in stride(from: 0, to: image.pixelsWide, by: 8) {
          guard let color = image.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else {
            continue
          }
          total +=
            0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722
            * color.blueComponent
          samples += 1
        }
      }
      return samples == 0 ? 0 : total / Double(samples)
    }

    static func inkCoverage(_ image: NSBitmapImageRep) -> Double {
      var counts: [UInt32: Int] = [:]
      var samples = 0
      for row in stride(from: 0, to: image.pixelsHigh, by: 4) {
        for column in stride(from: 0, to: image.pixelsWide, by: 4) {
          guard let color = image.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else {
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
