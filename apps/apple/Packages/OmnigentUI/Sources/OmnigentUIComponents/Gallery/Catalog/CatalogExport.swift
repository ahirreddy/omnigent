public import Foundation
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// What to export: which entries, appearances and devices, under which traits.
struct CatalogExportJob {
  var entries: [CatalogEntry]
  var directory: URL
  var schemes: [ColorScheme] = [.light, .dark]
  /// The screens whole pages render on (each entry uses the ones whose device it supports,
  /// else its first device).
  var screens = [CatalogScreen(.mac), CatalogScreen(.iPhone)]
  /// The screen components lay out for.
  var componentScreen = CatalogScreen(.mac)
  /// Draw iPhone, iPad and fold pages in their device frames.
  var framed = true
  var preferences: ThemePreferences
  var dynamicType: DynamicTypeSize = .large
  var increaseContrast = false
  var reduceMotion = false
  var rightToLeft = false
  /// How long each render settles before it is captured.
  var settleTime: Duration = .milliseconds(150)
}

/// One planned render.
struct CatalogExportItem: Hashable {
  let entryID: String
  let stateID: String
  let stateIndex: Int
  let screen: CatalogScreen
  let scheme: ColorScheme
  /// The PNG's file name, unique within the export.
  let fileName: String
}

/// The written files.
public struct GalleryExportReport: Sendable {
  /// The directory the PNGs were written to.
  public let directory: URL
  /// Every PNG, in catalog order.
  public let images: [URL]
  /// `index.html`, a contact sheet of every image.
  public let index: URL
  /// `manifest.json`, the entries, states and files for tools.
  public let manifest: URL
}

/// Why an export failed.
enum CatalogExportError: Error, CustomStringConvertible {
  case noEntries(filters: [String])
  case bitmapUnavailable(String)
  case encodingFailed(String)
  case noWindow

  var description: String {
    switch self {
    case .noEntries(let filters):
      "No catalog entry matches \(filters.joined(separator: ", "))."
    case .bitmapUnavailable(let name): "Could not draw \(name)."
    case .encodingFailed(let name): "Could not encode \(name) as PNG."
    case .noWindow: "The app has no window to render the gallery in."
    }
  }
}

enum CatalogExporter {
  /// Every render the job makes, in catalog order: each state of each entry, on each device the
  /// entry supports, in each appearance.
  static func plan(_ job: CatalogExportJob) -> [CatalogExportItem] {
    job.entries.flatMap { plan(job, entry: $0) }
  }

  static func plan(_ job: CatalogExportJob, entry: CatalogEntry) -> [CatalogExportItem] {
    screens(for: entry, job: job).flatMap { screen in
      entry.states.enumerated().flatMap { index, state in
        job.schemes.map { scheme in
          var parts = [entry.id]
          parts.append(
            entry.section == .flows ? "\(index < 9 ? "0" : "")\(index + 1)-\(state.id)" : state.id)
          if !entry.canvas.devices.isEmpty { parts.append(screen.id) }
          parts.append(traits(job, scheme: scheme, screen: screen).fileSuffix)
          return CatalogExportItem(
            entryID: entry.id, stateID: state.id, stateIndex: index, screen: screen,
            scheme: scheme, fileName: parts.joined(separator: "--") + ".png")
        }
      }
    }
  }

  static func screens(for entry: CatalogEntry, job: CatalogExportJob) -> [CatalogScreen] {
    let supported = entry.canvas.devices
    guard !supported.isEmpty else { return [job.componentScreen] }
    let chosen = job.screens.filter { supported.contains($0.device) }
    return chosen.isEmpty ? [CatalogScreen(supported[0])] : chosen
  }

  static func traits(_ job: CatalogExportJob, scheme: ColorScheme, screen: CatalogScreen)
    -> CatalogTraits
  {
    CatalogTraits(
      theme: job.preferences.theme, scheme: scheme, screen: screen, dynamicType: job.dynamicType,
      increaseContrast: job.increaseContrast, reduceMotion: job.reduceMotion,
      rightToLeft: job.rightToLeft)
  }

  /// Renders every planned item to `job.directory`, then writes the index and manifest.
  static func run(
    _ job: CatalogExportJob, progress: @MainActor (Int, Int) -> Void = { _, _ in }
  ) async throws -> GalleryExportReport {
    let items = plan(job)
    try FileManager.default.createDirectory(at: job.directory, withIntermediateDirectories: true)
    var images: [URL] = []
    for entry in job.entries {
      for item in plan(job, entry: entry) {
        progress(images.count, items.count)
        let data = try await render(
          entry.states[item.stateIndex],
          context: CatalogContext(screen: item.screen, preferences: job.preferences),
          traits: traits(job, scheme: item.scheme, screen: item.screen),
          layout: CatalogLayout(canvas: entry.canvas, screen: item.screen, framed: job.framed),
          name: item.fileName,
          settleTime: job.settleTime)
        let url = job.directory.appending(path: item.fileName)
        try data.write(to: url)
        images.append(url)
      }
    }
    progress(items.count, items.count)
    let index = job.directory.appending(path: "index.html")
    try CatalogExportIndex.html(entries: job.entries, items: items).write(
      to: index, atomically: true, encoding: .utf8)
    let manifest = job.directory.appending(path: "manifest.json")
    try CatalogExportIndex.manifest(entries: job.entries, items: items).write(to: manifest)
    return GalleryExportReport(
      directory: job.directory, images: images, index: index, manifest: manifest)
  }

  #if os(macOS)
    /// Draws a render through a real `NSHostingView` in a borderless window that is never
    /// shown, so AppKit-backed controls draw as they do in the app.
    static func render(
      _ state: CatalogState, context: CatalogContext, traits: CatalogTraits,
      layout: CatalogLayout, name: String, settleTime: Duration = .milliseconds(150)
    ) async throws -> Data {
      _ = NSApplication.shared
      let host = NSHostingView(
        rootView: AnyView(state.make(context).catalogRoot(traits, layout: layout)))
      host.sceneBridgingOptions = []
      host.appearance = CatalogAppearanceName.appearance(for: traits)
      let window = NSWindow(
        contentRect: CGRect(origin: .zero, size: CGSize(width: layout.width, height: 100)),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = host.appearance
      window.contentView = host
      resize(host, window: window, layout: layout)
      try await Task.sleep(for: settleTime)
      // Lazy content may change the fitting height once it has laid out.
      resize(host, window: window, layout: layout)
      try await Task.sleep(for: .milliseconds(20))
      host.layoutSubtreeIfNeeded()
      defer { window.orderOut(nil) }
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw CatalogExportError.bitmapUnavailable(name)
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CatalogExportError.encodingFailed(name)
      }
      return data
    }

    private static func resize(
      _ host: NSHostingView<AnyView>, window: NSWindow, layout: CatalogLayout
    ) {
      host.layoutSubtreeIfNeeded()
      let height = layout.height ?? max(host.fittingSize.height, 40)
      let size = CGSize(width: layout.width, height: height)
      window.setContentSize(size)
      host.frame = CGRect(origin: .zero, size: size)
      host.layoutSubtreeIfNeeded()
    }
  #else
    /// Draws a render through a `UIHostingController` placed off screen in the key window, so
    /// UIKit-backed controls draw as they do in the app.
    static func render(
      _ state: CatalogState, context: CatalogContext, traits: CatalogTraits,
      layout: CatalogLayout, name: String, settleTime: Duration = .milliseconds(150)
    ) async throws -> Data {
      let window = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
      guard let window else { throw CatalogExportError.noWindow }
      let controller = UIHostingController(
        rootView: AnyView(state.make(context).catalogRoot(traits, layout: layout)))
      controller.overrideUserInterfaceStyle = traits.scheme == .dark ? .dark : .light
      let fitting = controller.sizeThatFits(
        in: CGSize(width: layout.width, height: .greatestFiniteMagnitude))
      let size = CGSize(width: layout.width, height: layout.height ?? max(fitting.height, 40))
      controller.view.frame = CGRect(origin: CGPoint(x: -size.width - 100, y: 0), size: size)
      window.addSubview(controller.view)
      defer { controller.view.removeFromSuperview() }
      controller.view.layoutIfNeeded()
      try await Task.sleep(for: settleTime)
      let image = UIGraphicsImageRenderer(size: size).image { _ in
        controller.view.drawHierarchy(
          in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
      }
      guard let data = image.pngData() else { throw CatalogExportError.encodingFailed(name) }
      return data
    }
  #endif
}

/// The contact sheet and the manifest.
enum CatalogExportIndex {
  static func html(entries: [CatalogEntry], items: [CatalogExportItem]) -> String {
    var html = """
      <!doctype html><meta charset="utf-8"><title>Omnigent gallery</title>
      <style>
      body{font:14px -apple-system,sans-serif;margin:24px;background:#f5f5f7;color:#1d1d1f}
      h2{margin-top:40px}h3{margin:20px 0 4px}p{color:#6e6e73;margin:0 0 8px}
      .row{display:flex;flex-wrap:wrap;gap:16px;align-items:flex-start}
      figure{margin:0}img{max-width:640px;border:1px solid #d2d2d7;border-radius:8px;background:#fff}
      figcaption{font-size:12px;color:#6e6e73}
      </style>
      <h1>Omnigent gallery</h1>

      """
    for section in CatalogSection.allCases {
      let inSection = entries.filter { $0.section == section }
      guard !inSection.isEmpty else { continue }
      html += "<h2>\(escape(section.title))</h2>\n"
      for entry in inSection {
        html += "<h3 id=\"\(escape(entry.id))\">\(escape(entry.title))</h3>"
        html += "<p>\(escape(entry.summary)) <code>\(escape(entry.id))</code></p>\n"
        for (index, state) in entry.states.enumerated() {
          let files = items.filter { $0.entryID == entry.id && $0.stateIndex == index }
          guard !files.isEmpty else { continue }
          html +=
            "<p><b>\(escape(state.title))</b>\(state.note.map { " \u{2014} " + escape($0) } ?? "")</p>"
          html += "<div class=\"row\">"
          for file in files {
            let caption = "\(file.screen.title) \u{00B7} \(file.scheme == .dark ? "Dark" : "Light")"
            html +=
              "<figure><a href=\"\(escape(file.fileName))\"><img loading=\"lazy\" src=\"\(escape(file.fileName))\"></a>"
            html += "<figcaption>\(escape(caption))</figcaption></figure>"
          }
          html += "</div>\n"
        }
      }
    }
    return html
  }

  static func manifest(entries: [CatalogEntry], items: [CatalogExportItem]) throws -> Data {
    let records = entries.map { entry in
      ManifestEntry(
        id: entry.id, section: entry.section.rawValue, area: entry.area.rawValue,
        title: entry.title, summary: entry.summary,
        states: entry.states.enumerated().map { index, state in
          ManifestState(
            id: state.id, title: state.title, note: state.note, branchesFrom: state.branchesFrom,
            files: items.filter { $0.entryID == entry.id && $0.stateIndex == index }.map(\.fileName)
          )
        })
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(records)
  }

  private static func escape(_ text: String) -> String {
    text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
      .replacing("\"", with: "&quot;")
  }

  private struct ManifestEntry: Encodable {
    let id: String
    let section: String
    let area: String
    let title: String
    let summary: String
    let states: [ManifestState]
  }

  private struct ManifestState: Encodable {
    let id: String
    let title: String
    let note: String?
    let branchesFrom: String?
    let files: [String]
  }
}
