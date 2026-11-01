import OmnigentPlatform
import SwiftUI

/// Layout metrics and semantic styles for the components. Colors come from the system (so they
/// follow light, dark and increased contrast) or from ``DesignTokens`` where the web UI defines
/// them.
enum Theme {
  enum Spacing {
    static let paragraph: CGFloat = 10
    static let row: CGFloat = 18
    static let card: CGFloat = 12
    static let gutter: CGFloat = 20
  }

  enum Radius {
    static let small: CGFloat = 6
    static let medium: CGFloat = DesignTokens.radius
    static let large: CGFloat = 12
    static let bubble: CGFloat = 16
  }

  /// The readable column width of the transcript.
  static let transcriptWidth: CGFloat = 780

  static let codeFont = Font.system(.footnote, design: .monospaced)

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

/// A rounded card surface: a material on platforms that render vibrancy, an opaque fill when
/// Reduce Transparency is on.
struct CardSurface: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  var cornerRadius: CGFloat = Theme.Radius.large
  var tint: ThemeColor?
  var stroke: ThemeColor?

  func body(content: Content) -> some View {
    content
      .background {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
          if reduceTransparency {
            shape.fill(Color.secondary.opacity(0.12))
          } else {
            shape.fill(.background.secondary)
          }
          if let tint { shape.fill(tint.opacity(0.08)) }
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(stroke ?? Theme.secondary.opacity(0.18), lineWidth: stroke == nil ? 0.5 : 1)
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
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(Color.primary.opacity(isHovered ? 0.05 : 0))
      )
      .onHover { isHovered = $0 }
  }
}

/// A borderless copy button with a brief confirmation.
struct CopyButton: View {
  let text: String
  var label = "Copy"
  /// The button's accessibility identifier.
  var identifier: String?
  @State private var copied = false

  var body: some View {
    Button {
      Pasteboard.copy(text)
      copied = true
    } label: {
      Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        .labelStyle(.iconOnly)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
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
