import OmnigentPlatform
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
    #if os(macOS)
      static let proseSize: CGFloat = 15
    #else
      static let proseSize: CGFloat = 17
    #endif
    static let leading: CGFloat = 5
    static let editorLineHeight = proseSize + leading
    static let title = Font.title2.weight(.semibold)
    static let label = Font.callout.weight(.medium)
    static let section = Font.caption.weight(.medium)
    static let code = Font.system(.callout, design: .monospaced)
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

  static let codeFont = Typography.code

  static var codeBackground: Color { Color.secondary.opacity(0.1) }

  // Brand colors come from the environment's `OmnigentTheme`; these resolve at render time.
  static let accent = ThemeColor.accent
  static let brandAccent = ThemeColor.brandAccent
  static let userBubble = ThemeColor.userBubble
  static let running = ThemeColor.running
  /// "Needs response" and other things waiting on the user: the brand accent, as the web.
  static let attention = ThemeColor.brandAccent
  static let warning = ThemeColor.warning
  static let success = ThemeColor.success
  static let info = ThemeColor.info
  static let failure = ThemeColor.failure
  static let unread = ThemeColor.brandAccent
  static let link = ThemeColor.link
  static let secondary = ThemeColor.secondary

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
    if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var color: ThemeColor = Theme.running

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 7, height: 7)
      .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.3]) { dot, opacity in
        dot.opacity(opacity)
      } animation: { _ in
        .easeInOut(duration: 0.7)
      }
      .accessibilityLabel("Live")
  }
}

/// Three animated dots shown while the agent is working and nothing is streaming yet.
struct TypingIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 4) {
      ForEach(0..<3, id: \.self) { index in
        Circle()
          .fill(.secondary)
          .frame(width: 6, height: 6)
          .phaseAnimator(reduceMotion ? [1.0] : [0.25, 1.0]) { dot, opacity in
            dot.opacity(opacity)
          } animation: { _ in
            .easeInOut(duration: 0.5).delay(Double(index) * 0.15)
          }
      }
    }
    .accessibilityElement()
    .accessibilityLabel("The agent is working")
  }
}
