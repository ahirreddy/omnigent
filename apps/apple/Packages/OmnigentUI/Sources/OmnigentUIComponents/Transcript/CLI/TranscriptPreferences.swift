public import Foundation
public import Observation

/// Device-local transcript preferences, stored in `UserDefaults` beside the theme keys: the
/// style, and per style the content width and output rendering, plus the CLI font size.
@Observable
public final class TranscriptPreferences {
  /// `omnigent:transcript-style`: `chat` or `cli`.
  public static let styleKey = "omnigent:transcript-style"
  /// `omnigent:cli-font-size`: points.
  public static let fontSizeKey = "omnigent:cli-font-size"

  /// The content width key for `style`.
  /// - Parameter style: A transcript style.
  /// - Returns: `omnigent:<style>-content-width`.
  public static func widthKey(_ style: TranscriptStyle) -> String {
    "omnigent:\(style.rawValue)-content-width"
  }

  /// The output rendering key for `style`.
  /// - Parameter style: A transcript style.
  /// - Returns: `omnigent:<style>-output-rendering`.
  public static func renderingKey(_ style: TranscriptStyle) -> String {
    "omnigent:\(style.rawValue)-output-rendering"
  }

  /// Chat or CLI.
  public var style: TranscriptStyle {
    didSet { defaults.set(style.rawValue, forKey: Self.styleKey) }
  }
  /// The CLI font size, in points; ``appearance(style:)`` clamps it to the supported range.
  public var fontSize: Double {
    didSet { defaults.set(fontSize, forKey: Self.fontSizeKey) }
  }
  /// Problems found reading stored values, for Settings to show.
  public private(set) var readErrors: [ThemePreferences.ReadError] = []

  private var widths: [TranscriptStyle: TranscriptContentWidth]
  private var renderings: [TranscriptStyle: OutputRendering]
  private let defaults: UserDefaults

  /// Loads preferences.
  /// - Parameter defaults: The store; `standard` by default.
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    var errors: [ThemePreferences.ReadError] = []
    func read<Value: RawRepresentable<String>>(_ key: String, as _: Value.Type) -> Value? {
      guard let stored = defaults.string(forKey: key) else { return nil }
      guard let value = Value(rawValue: stored) else {
        errors.append(.malformed(key: key))
        return nil
      }
      return value
    }
    style = read(Self.styleKey, as: TranscriptStyle.self) ?? .chat
    var widths: [TranscriptStyle: TranscriptContentWidth] = [:]
    var renderings: [TranscriptStyle: OutputRendering] = [:]
    for style in TranscriptStyle.allCases {
      widths[style] = read(Self.widthKey(style), as: TranscriptContentWidth.self)
      renderings[style] = read(Self.renderingKey(style), as: OutputRendering.self)
    }
    self.widths = widths
    self.renderings = renderings
    if let stored = defaults.object(forKey: Self.fontSizeKey) {
      if let size = stored as? Double, TranscriptAppearance.fontSizes.contains(size) {
        fontSize = size
      } else {
        fontSize = TranscriptAppearance.defaultFontSize
        errors.append(.malformed(key: Self.fontSizeKey))
      }
    } else {
      fontSize = TranscriptAppearance.defaultFontSize
    }
    readErrors = errors
  }

  /// The content width for `style`: the stored choice or the style's default.
  /// - Parameter style: A transcript style.
  /// - Returns: The width.
  public func contentWidth(for style: TranscriptStyle) -> TranscriptContentWidth {
    widths[style] ?? .defaultValue(for: style)
  }

  /// Stores the content width for `style`.
  /// - Parameters:
  ///   - width: The width.
  ///   - style: A transcript style.
  public func setContentWidth(_ width: TranscriptContentWidth, for style: TranscriptStyle) {
    widths[style] = width
    defaults.set(width.rawValue, forKey: Self.widthKey(style))
  }

  /// The output rendering for `style`: the stored choice or the style's default.
  /// - Parameter style: A transcript style.
  /// - Returns: The rendering.
  public func outputRendering(for style: TranscriptStyle) -> OutputRendering {
    renderings[style] ?? .defaultValue(for: style)
  }

  /// Stores the output rendering for `style`.
  /// - Parameters:
  ///   - rendering: The rendering.
  ///   - style: A transcript style.
  public func setOutputRendering(_ rendering: OutputRendering, for style: TranscriptStyle) {
    renderings[style] = rendering
    defaults.set(rendering.rawValue, forKey: Self.renderingKey(style))
  }

  /// The content width of the current style.
  public var contentWidth: TranscriptContentWidth {
    get { contentWidth(for: style) }
    set { setContentWidth(newValue, for: style) }
  }

  /// The output rendering of the current style.
  public var outputRendering: OutputRendering {
    get { outputRendering(for: style) }
    set { setOutputRendering(newValue, for: style) }
  }

  /// The appearance to render with, optionally with a window's own style.
  /// - Parameter override: A per-window style; the stored style when `nil`.
  /// - Returns: The resolved appearance.
  public func appearance(style override: TranscriptStyle? = nil) -> TranscriptAppearance {
    let style = override ?? style
    return TranscriptAppearance(
      style: style, contentWidth: contentWidth(for: style),
      outputRendering: outputRendering(for: style), fontSize: fontSize)
  }
}
