public import Foundation
import SwiftUI

/// How the gallery was asked to start, from launch arguments and the environment.
///
/// - `-OmnigentGallery` (or `--gallery`): open the gallery.
/// - `--gallery-entry <id>` (`OMNIGENT_GALLERY_ENTRY`): the entry to show first.
/// - `--gallery-state <id>` (`OMNIGENT_GALLERY_STATE`): its state or flow step.
/// - `--gallery-device <id>` (`OMNIGENT_GALLERY_DEVICE`): the device the gallery starts on, for
///   example `iPhone`, `iPadPro13-landscape` or `duo-unfolded`.
/// - `--gallery-frames <on|off>` (`OMNIGENT_GALLERY_FRAMES`): draw device frames, on by default.
/// - `--export-gallery <dir>` (`OMNIGENT_GALLERY_EXPORT`): write PNGs and quit.
/// - `--gallery-filter <a,b>` (`OMNIGENT_GALLERY_FILTER`): export entries whose id or title
///   contains any term.
/// - `--gallery-theme <id>` (`OMNIGENT_GALLERY_THEME`): the palette, `omni` by default.
/// - `--gallery-devices <ids>` (`OMNIGENT_GALLERY_DEVICES`): the devices pages export on, as
///   device ids with an optional `-landscape` or `-unfolded`; `mac,iPhone` by default.
/// - `--gallery-appearances <light,dark>` (`OMNIGENT_GALLERY_APPEARANCES`).
/// - `--gallery-accessibility <contrast,reduce-transparency,reduce-motion>`
///   (`OMNIGENT_GALLERY_ACCESSIBILITY`): accessibility settings for every render.
/// - `--gallery-capture <view|window>` (`OMNIGENT_GALLERY_CAPTURE`): `window` captures through the
///   window server so Liquid Glass draws (Mac; needs Screen Recording permission).
public struct GalleryLaunchOptions: Sendable, Equatable {
  /// Open the gallery.
  public var showsGallery = false
  /// The entry to show first.
  public var entryID: String?
  /// The entry's state or flow step to show first.
  public var stateID: String?
  /// The device id the gallery starts on, for example `iPhone` or `duo-unfolded`.
  public var device: String?
  /// Draw iPhone, iPad and fold pages in their device frames.
  public var frames = true
  /// Export to this directory, then quit.
  public var exportDirectory: URL?
  /// Export only entries whose id or title contains one of these.
  public var filters: [String] = []
  /// The palette id.
  public var themeID = OmnigentTheme.omni.id
  /// Device ids for page exports.
  public var devices = ["mac", "iPhone"]
  /// `light` and or `dark`.
  public var appearances = ["light", "dark"]
  /// Accessibility settings for every render: `contrast`, `reduce-transparency`, `reduce-motion`.
  public var accessibility: [String] = []
  /// Capture through the window server, so Liquid Glass draws.
  public var capturesWindow = false

  /// The accepted ``accessibility`` values.
  static let accessibilitySettings = ["contrast", "reduce-transparency", "reduce-motion"]

  /// A bad launch argument.
  public enum ParseError: Error, Equatable, CustomStringConvertible {
    /// An option without its value.
    case missingValue(String)
    /// A value the option does not accept.
    case invalidValue(option: String, value: String, expected: String)

    /// The message.
    public var description: String {
      switch self {
      case .missingValue(let option): "\(option) needs a value."
      case .invalidValue(let option, let value, let expected):
        "\(option) does not accept \(value); expected \(expected)."
      }
    }
  }

  /// Options with every default: nothing requested.
  public init() {}

  /// Parses `arguments` (after the executable) and `environment`; arguments win.
  /// - Parameters:
  ///   - arguments: The process arguments, executable first.
  ///   - environment: The process environment.
  /// - Throws: ``ParseError`` for an option without its value or with a value it does not accept.
  public init(arguments: [String], environment: [String: String]) throws {
    var options = Self()
    try options.apply(environment: environment)
    try options.apply(arguments: Array(arguments.dropFirst()))
    try options.validate()
    self = options
  }

  /// Whether the process should export and quit.
  public var exports: Bool { exportDirectory != nil }

  /// The environment variable for each option.
  private static let environmentOptions: KeyValuePairs<String, String> = [
    "OMNIGENT_GALLERY_ENTRY": "--gallery-entry", "OMNIGENT_GALLERY_STATE": "--gallery-state",
    "OMNIGENT_GALLERY_DEVICE": "--gallery-device", "OMNIGENT_GALLERY_FRAMES": "--gallery-frames",
    "OMNIGENT_GALLERY_EXPORT": "--export-gallery", "OMNIGENT_GALLERY_FILTER": "--gallery-filter",
    "OMNIGENT_GALLERY_THEME": "--gallery-theme", "OMNIGENT_GALLERY_DEVICES": "--gallery-devices",
    "OMNIGENT_GALLERY_APPEARANCES": "--gallery-appearances",
    "OMNIGENT_GALLERY_ACCESSIBILITY": "--gallery-accessibility",
    "OMNIGENT_GALLERY_CAPTURE": "--gallery-capture",
  ]

  /// Applies the environment as the equivalent arguments.
  private mutating func apply(environment: [String: String]) throws {
    let arguments = Self.environmentOptions.flatMap { variable, option in
      environment[variable].map { [option, $0] } ?? []
    }
    try apply(arguments: arguments)
  }

  /// The options that take a value, and where each value goes.
  private static let valueOptions: [String: (inout Self, String) -> Void] = [
    "-OmnigentGalleryEntry": { $0.entryID = $1 }, "--gallery-entry": { $0.entryID = $1 },
    "--gallery-state": { $0.stateID = $1 }, "--gallery-device": { $0.device = $1 },
    "-OmnigentGalleryExport": {
      $0.exportDirectory = URL(filePath: $1, directoryHint: .isDirectory)
    },
    "--export-gallery": { $0.exportDirectory = URL(filePath: $1, directoryHint: .isDirectory) },
    "--gallery-filter": { $0.filters = list($1) }, "--gallery-theme": { $0.themeID = $1 },
    "--gallery-devices": { $0.devices = list($1) },
    "--gallery-appearances": { $0.appearances = list($1) },
    "--gallery-accessibility": { $0.accessibility = list($1) },
  ]

  private mutating func apply(arguments: [String]) throws {
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
      if argument == "-OmnigentGallery" || argument == "--gallery" {
        showsGallery = true
      } else if argument == "--gallery-frames" {
        guard let value = remaining.popFirst() else { throw ParseError.missingValue(argument) }
        try setFrames(value)
      } else if argument == "--gallery-capture" {
        guard let value = remaining.popFirst() else { throw ParseError.missingValue(argument) }
        try setCapture(value)
      } else if let set = Self.valueOptions[argument] {
        guard let value = remaining.popFirst() else { throw ParseError.missingValue(argument) }
        set(&self, value)
      }
      // Anything else belongs to the host app (Xcode adds its own arguments, too).
    }
    if entryID != nil || exportDirectory != nil { showsGallery = true }
  }

  private mutating func setFrames(_ value: String) throws {
    switch value {
    case "on": frames = true
    case "off": frames = false
    default:
      throw ParseError.invalidValue(option: "--gallery-frames", value: value, expected: "on, off")
    }
  }

  private mutating func setCapture(_ value: String) throws {
    switch value {
    case "view": capturesWindow = false
    case "window": capturesWindow = true
    default:
      throw ParseError.invalidValue(
        option: "--gallery-capture", value: value, expected: "view, window")
    }
  }

  private func validate() throws {
    let themes = OmnigentTheme.builtIn.map(\.id) + ["custom"]
    guard themes.contains(themeID) else {
      throw ParseError.invalidValue(
        option: "--gallery-theme", value: themeID, expected: themes.joined(separator: ", "))
    }
    for device in devices + [device].compactMap(\.self) where CatalogScreen(id: device) == nil {
      throw ParseError.invalidValue(
        option: "--gallery-devices", value: device,
        expected: CatalogScreen.all.map(\.id).joined(separator: ", "))
    }
    for setting in accessibility where !Self.accessibilitySettings.contains(setting) {
      throw ParseError.invalidValue(
        option: "--gallery-accessibility", value: setting,
        expected: Self.accessibilitySettings.joined(separator: ", "))
    }
    for appearance in appearances where !["light", "dark"].contains(appearance) {
      throw ParseError.invalidValue(
        option: "--gallery-appearances", value: appearance, expected: "light, dark")
    }
  }

  private static func list(_ value: String) -> [String] {
    value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
}

/// Writes catalog entries to PNGs, with an `index.html` contact sheet and a `manifest.json`.
public enum GallerySnapshotExport {
  /// Exports what `options` asks for.
  /// - Parameters:
  ///   - options: The parsed launch options; `exportDirectory` must be set.
  ///   - progress: Called with the number of images written and the total.
  /// - Returns: The written files.
  /// - Throws: A missing export directory, no matching entries, a render that could not be
  ///   drawn or encoded, or a file that could not be written.
  public static func run(
    _ options: GalleryLaunchOptions, progress: @MainActor (Int, Int) -> Void = { _, _ in }
  ) async throws -> GalleryExportReport {
    guard let directory = options.exportDirectory else {
      throw GalleryLaunchOptions.ParseError.missingValue("--export-gallery")
    }
    let entries = GalleryCatalog.filtered(GalleryCatalog.entries, by: options.filters)
    guard !entries.isEmpty else { throw CatalogExportError.noEntries(filters: options.filters) }
    let preferences = ThemePreferences(defaults: CatalogSettings.scratchDefaults)
    preferences.mode = .system
    preferences.paletteID = options.themeID
    let job = CatalogExportJob(
      entries: entries, directory: directory,
      schemes: options.appearances.map { $0 == "dark" ? ColorScheme.dark : .light },
      screens: options.devices.compactMap(CatalogScreen.init(id:)), framed: options.frames,
      preferences: preferences, increaseContrast: options.accessibility.contains("contrast"),
      reduceTransparency: options.accessibility.contains("reduce-transparency"),
      reduceMotion: options.accessibility.contains("reduce-motion"),
      capturesWindow: options.capturesWindow)
    return try await CatalogExporter.run(job, progress: progress)
  }

  /// The catalog's size, for logs: entries per section.
  public static var summary: String { CatalogSidebar.summary(GalleryCatalog.entries) }
}
