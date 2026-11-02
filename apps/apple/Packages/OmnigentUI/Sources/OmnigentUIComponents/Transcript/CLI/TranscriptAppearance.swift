public import SwiftUI

/// How the transcript lays out turns.
nonisolated public enum TranscriptStyle: String, Hashable, Sendable, CaseIterable, Identifiable {
  /// User bubbles on the right, prose on the left (the default).
  case chat
  /// A terminal look: user input in full-width bands, `•` output blocks, monospaced text.
  case cli

  /// The style itself.
  public var id: Self { self }

  /// The display title.
  public var title: String {
    switch self {
    case .chat: "Chat"
    case .cli: "CLI"
    }
  }

  /// The other style.
  public var toggled: Self { self == .chat ? .cli : .chat }
}

/// How wide the transcript, dock and composer may grow.
nonisolated public enum TranscriptContentWidth: String, Hashable, Sendable, CaseIterable,
  Identifiable
{
  /// A comfortable reading column.
  case reading
  /// A wider column for tables and code.
  case wide
  /// The full width of the window, with modest padding.
  case edgeToEdge

  /// The width itself.
  public var id: Self { self }

  /// The display title.
  public var title: String {
    switch self {
    case .reading: "Reading column"
    case .wide: "Wide"
    case .edgeToEdge: "Edge to edge"
    }
  }

  /// The column's maximum width.
  @MainActor public var maxWidth: CGFloat {
    switch self {
    case .reading: Theme.transcriptWidth
    case .wide: 1_080
    case .edgeToEdge: .infinity
    }
  }

  /// The default for `style`.
  /// - Parameter style: A transcript style.
  /// - Returns: Reading column for chat, edge to edge for CLI.
  public static func defaultValue(for style: TranscriptStyle) -> Self {
    style == .cli ? .edgeToEdge : .reading
  }
}

/// How agent output text renders.
nonisolated public enum OutputRendering: String, Hashable, Sendable, CaseIterable, Identifiable {
  /// The text exactly as emitted, monospaced, with light syntax tinting only.
  case plain
  /// Terminal-style markdown: literal heading markers, accent colors, ruled tables.
  case styled
  /// The chat view's rich markdown: code cards, tables, typeset headings.
  case rich

  /// The rendering itself.
  public var id: Self { self }

  /// The display title.
  public var title: String {
    switch self {
    case .plain: "Plain"
    case .styled: "Styled"
    case .rich: "Rich"
    }
  }

  /// A one-line explanation for Settings.
  public var detail: String {
    switch self {
    case .plain: "Exactly as the agent wrote it, with light syntax tinting."
    case .styled: "Terminal-style formatting: accent headings, colored code, ruled tables."
    case .rich: "Formatted like chat: typeset headings, code cards and tables."
    }
  }

  /// The default for `style`.
  /// - Parameter style: A transcript style.
  /// - Returns: Plain for CLI, rich for chat.
  public static func defaultValue(for style: TranscriptStyle) -> Self {
    style == .cli ? .plain : .rich
  }
}

/// The resolved transcript presentation a window renders with.
nonisolated public struct TranscriptAppearance: Hashable, Sendable {
  /// The CLI font size range, in points.
  public static let fontSizes: ClosedRange<Double> = 10...22
  #if os(macOS)
    /// The default CLI font size: the Mac terminal's.
    public static let defaultFontSize: Double = 13
  #else
    /// The default CLI font size, before Dynamic Type.
    public static let defaultFontSize: Double = 15
  #endif

  // The `Double` comes first so the one-byte enums leave no padding between fields: SwiftUI
  // compares plain-data environment values bytewise (see ``SRGB``).
  /// The CLI monospaced font size, in points.
  public var fontSize: Double
  /// Chat or CLI.
  public var style: TranscriptStyle
  /// The column width.
  public var contentWidth: TranscriptContentWidth
  /// How agent output renders.
  public var outputRendering: OutputRendering

  /// Creates an appearance; widths and renderings default per style.
  /// - Parameters:
  ///   - style: Chat or CLI.
  ///   - contentWidth: Column width; the style's default when `nil`.
  ///   - outputRendering: Output rendering; the style's default when `nil`.
  ///   - fontSize: CLI font size.
  public init(
    style: TranscriptStyle = .chat, contentWidth: TranscriptContentWidth? = nil,
    outputRendering: OutputRendering? = nil, fontSize: Double = Self.defaultFontSize
  ) {
    self.style = style
    self.contentWidth = contentWidth ?? .defaultValue(for: style)
    self.outputRendering = outputRendering ?? .defaultValue(for: style)
    self.fontSize = min(max(fontSize, Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
  }

  /// CLI style is on.
  public var isCLI: Bool { style == .cli }
}

extension EnvironmentValues {
  /// The transcript presentation. Set it with ``SwiftUICore/View/transcriptAppearance(_:)``.
  @Entry public var transcriptAppearance = TranscriptAppearance()
}

extension View {
  /// Applies a transcript presentation to the conversation views below.
  /// - Parameter appearance: The presentation.
  /// - Returns: The view.
  public func transcriptAppearance(_ appearance: TranscriptAppearance) -> some View {
    environment(\.transcriptAppearance, appearance)
  }

  /// The transcript, dock and composer column for the current appearance: the chat reading
  /// column, or the configured width.
  func transcriptColumn() -> some View { modifier(TranscriptColumn()) }

  /// The column for a whole transcript stack in chat style; CLI rows set their own.
  func transcriptStackColumn() -> some View { modifier(TranscriptStackColumn()) }
}

private struct TranscriptStackColumn: ViewModifier {
  @Environment(\.transcriptAppearance) private var appearance

  func body(content: Content) -> some View {
    if appearance.isCLI {
      content.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    } else {
      content.transcriptColumn()
    }
  }
}

/// Bounds content to the configured width with the gutter, centered in the available space.
struct TranscriptColumn: ViewModifier {
  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.transcriptAppearance) private var appearance
  private let size = CLIFontSize()

  func body(content: Content) -> some View {
    // Compact width is always edge to edge; there is no room for a narrower column.
    let maxWidth = layoutWidth == .compact ? .infinity : appearance.contentWidth.maxWidth
    content
      .frame(minWidth: 0, maxWidth: maxWidth, alignment: .leading)
      .padding(.horizontal, gutter)
      .frame(minWidth: 0, maxWidth: .infinity)
  }

  private var gutter: CGFloat {
    if appearance.isCLI {
      // The `•` and `›` markers hang in the gutter, so it always fits two characters.
      let markers = size.character * CGFloat(CLIMetrics.markerColumns)
      let minimum = layoutWidth == .compact ? CLIMetrics.compactGutter : CLIMetrics.gutter
      return max(minimum, markers + Theme.Spacing.extraSmall)
    }
    return layoutWidth == .compact ? Theme.Spacing.compactGutter : Theme.Spacing.gutter
  }
}

/// A screen's own canvas for the toolbar row behind its title (the iPhone navigation bar too),
/// when it differs from the theme's: CLI style puts it on the terminal background.
struct TitlebarCanvasKey: PreferenceKey {
  static let defaultValue: Color? = nil

  static func reduce(value: inout Color?, nextValue: () -> Color?) {
    value = value ?? nextValue()
  }
}

/// CLI layout metrics, in points.
enum CLIMetrics {
  /// Horizontal padding at regular width.
  static let gutter: CGFloat = 16
  /// Horizontal padding at compact width.
  static let compactGutter: CGFloat = 10
  /// The vertical gap between blocks: one blank terminal line.
  static let blockGap: CGFloat = 14
  /// The user band's vertical padding.
  static let bandPadding: CGFloat = 14
  /// The width of the `•` / `›` marker column, in character widths.
  static let markerColumns = 2
}
