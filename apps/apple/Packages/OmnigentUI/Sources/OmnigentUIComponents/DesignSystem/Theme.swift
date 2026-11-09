import OmnigentPlatform
import OmnigentWorkspaceUI
import SwiftUI

/// Layout metrics and semantic styles for the components. Colors come from the system (so they
/// follow light, dark and increased contrast) or from ``DesignTokens`` where the web UI defines
/// them.
enum Theme {
  enum Spacing {
    static let tiny: CGFloat = 2
    static let extraSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let extraLarge: CGFloat = 24
    static let section: CGFloat = 32
    static let paragraph = large
    static let row = extraLarge
    static let card = large
    static let gutter = extraLarge
    static let compactGutter = medium
  }

  enum Radius {
    static let small: CGFloat = 8
    static let medium: CGFloat = DesignTokens.radius
    static let large: CGFloat = 16
    static let bubble: CGFloat = 20
    static let composer: CGFloat = 24
  }

  /// The readable column width of the transcript.
  static let transcriptWidth: CGFloat = 720
  static let inboxWidth: CGFloat = 880
  static let userMessageWidth: CGFloat = 560

  enum Typography {
    /// Body prose; the transcript's sizes derive from it (``TypeRamp``).
    static let proseSize = TypeRamp.defaultBody
    /// The composer's extra leading; the transcript uses ``TypeRamp`` line heights.
    static let leading: CGFloat = 5
    static let editorLineHeight = proseSize + leading
    static let title = Font.title2.weight(.semibold)
    static let label = Font.callout.weight(.medium)
    static let section = Font.caption.weight(.medium)
    /// Code, sized by Settings › Appearance › Code typography (callout size by default).
    static var code: Font { CodeTypography.shared.font(size: 12) }
  }

  enum Control {
    #if os(macOS)
      static let target: CGFloat = 28
      static let send: CGFloat = 34
      static let sidebarRow: CGFloat = 32
    #else
      static let target: CGFloat = 44
      static let send: CGFloat = 44
      static let sidebarRow: CGFloat = 44
    #endif
    static let compactModelWidth: CGFloat = 130
    static let modelWidth: CGFloat = 220
    static let serverNameWidth: CGFloat = 130
    static let icon: CGFloat = 16
    static let mascot: CGFloat = 44
    static let dockHeight: CGFloat = 320
    static let compactDockHeight: CGFloat = 240
  }

  enum Motion {
    static let feedback = Animation.easeOut(duration: 0.16)
    static let disclosure = Animation.easeInOut(duration: 0.2)
  }

  static var codeFont: Font { Typography.code }

  static var codeBackground: Color { Color.secondary.opacity(0.1) }

  // Brand colors come from the environment's `OmnigentTheme`; these resolve at render time.
  // Emphasis discipline: the accent is for the one primary action on a screen and the brand
  // accent for "needs you". Everything else is neutral or a labelled status color.
  static let accent = ThemeColor.accent
  /// "Needs you": the brand accent, kept legible on every surface (``ThemeColor/attention``).
  static let brandAccent = ThemeColor.attention
  static let userBubble = ThemeColor.userBubble
  static let running = ThemeColor.running
  /// "Needs response" and other things waiting on the user: the brand accent, as the web.
  static let attention = ThemeColor.attention
  static let warning = ThemeColor.warning
  static let success = ThemeColor.success
  static let info = ThemeColor.info
  static let failure = ThemeColor.failure
  /// Unread is not "needs you": a calm status blue, never the brand accent.
  static let unread = ThemeColor.info
  /// A selected row: the softened theme selection.
  static let selection = ThemeColor.rowSelection
  /// A focused field's border.
  static let focus = ThemeColor.focus
  static let link = ThemeColor.link
  static let secondary = ThemeColor.secondary
  /// Secondary text that keeps WCAG AA on sidebars and selected rows.
  static let mutedText = ThemeColor.mutedText

  static func lineCount(_ text: String) -> Int {
    text.reduce(into: 1) { count, character in
      if character == "\n" { count += 1 }
    }
  }

  static func relativeDate(_ date: Date, now: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) {
      return date.formatted(date: .omitted, time: .shortened)
    }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    // A weekday means the past week; a date ahead of the clock needs its full date.
    if let days = calendar.dateComponents([.day], from: date, to: now).day, (0..<7).contains(days) {
      formatter.setLocalizedDateFormatFromTemplate("EEE")
    } else {
      formatter.setLocalizedDateFormatFromTemplate("MMMd")
    }
    return formatter.string(from: date)
  }
}

/// An opaque, theme-derived card with a semantic border and optional status wash.
struct CardSurface: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  var cornerRadius: CGFloat = Theme.Radius.large
  var tint: ThemeColor?
  var stroke: ThemeColor?

  func body(content: Content) -> some View {
    content
      .background {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
          shape.fill(ThemeColor.surface)
          if let tint { shape.fill(tint.opacity(reduceTransparency ? 0.04 : 0.05)) }
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(
            contrast == .increased ? ThemeColor.border : (stroke ?? ThemeColor.border),
            lineWidth: contrast == .increased ? 1.5 : 0.5)
      }
  }
}

extension View {
  func cardSurface(
    cornerRadius: CGFloat = Theme.Radius.large, tint: ThemeColor? = nil, stroke: ThemeColor? = nil
  )
    -> some View
  {
    modifier(CardSurface(cornerRadius: cornerRadius, tint: tint, stroke: stroke))
  }

  /// A selected item's fill: the softened theme selection, in a rounded rectangle.
  func selectionFill(_ isSelected: Bool, cornerRadius: CGFloat = Theme.Radius.small) -> some View {
    background(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(isSelected ? AnyShapeStyle(Theme.selection) : AnyShapeStyle(.clear)))
  }

  /// A subtle hover highlight for pointer platforms.
  func hoverHighlight(cornerRadius: CGFloat = Theme.Radius.small) -> some View {
    modifier(HoverHighlight(cornerRadius: cornerRadius))
  }
}

private struct HoverHighlight: ViewModifier {
  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(ThemeColor.hover.opacity(isHovered && isEnabled ? 1 : 0))
      )
      .onHover { isHovered = $0 }
      .animation(reduceMotion ? nil : Theme.Motion.feedback, value: isHovered)
  }
}

/// A borderless copy button with a brief confirmation.
struct CopyButton: View {
  let text: String
  var label = "Copy"
  /// The button's accessibility identifier.
  var identifier: String?
  var showsLabel = false
  @State private var copied = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button {
      Pasteboard.copy(text)
      copied = true
    } label: {
      Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        .labelStyle(CopyLabelStyle(showsTitle: showsLabel))
        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        .frame(minWidth: Theme.Control.target, minHeight: Theme.Control.target)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .hoverHighlight()
    .help(label)
    .accessibilityLabel(copied ? "Copied" : label)
    .accessibilityIdentifier(identifier ?? "", isEnabled: identifier != nil)
    .task(id: copied) {
      guard copied else { return }
      do {
        try await Task.sleep(for: .seconds(1.5))
      } catch {
        // Cancelled because the button went away; there is nothing left to reset.
        return
      }
      copied = false
    }
  }
}

private struct CopyLabelStyle: LabelStyle {
  let showsTitle: Bool

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      configuration.icon
      if showsTitle { configuration.title }
    }
    .font(Theme.Typography.section)
  }
}

/// A small capsule badge.
struct Pill: View {
  let text: String
  var systemImage: String?
  var tint: ThemeColor = .secondary

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage {
        Image(systemName: systemImage).imageScale(.small)
          .accessibilityHidden(true)
      }
      Text(text).lineLimit(1)
    }
    .font(.caption.weight(.medium))
    .padding(.horizontal, 7)
    .padding(.vertical, 2.5)
    .foregroundStyle(tint)
    .background(tint.opacity(0.12), in: Capsule())
    .accessibilityElement(children: .combine)
  }
}

/// A pulsing dot that marks live, streaming content. Static under Reduce Motion.
struct LiveIndicator: View {
  var color: ThemeColor = Theme.running

  var body: some View {
    LoopingIndicator(
      shape: .dot(diameter: 7), motion: .fade(low: 0.3, duration: 0.7), color: color
    )
    .frame(width: 7, height: 7)
    .accessibilityElement()
    .accessibilityLabel("Live")
  }
}

/// Three animated dots shown while the agent is working and nothing is streaming yet.
struct TypingIndicator: View {
  var body: some View {
    LoopingIndicator(
      shape: .dots(count: 3, diameter: 6, spacing: 4),
      motion: .fade(low: 0.25, duration: 0.5, stagger: 0.15)
    )
    .frame(width: 26, height: 6)
    .accessibilityElement()
    .accessibilityLabel("The agent is working")
  }
}
