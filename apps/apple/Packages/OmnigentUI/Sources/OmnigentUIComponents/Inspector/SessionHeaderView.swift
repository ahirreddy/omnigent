public import SwiftUI

/// The session's status line: title (optional, since the Mac shows it in the window title),
/// the one status line (``SessionStatusLine``), harness and model, context usage, viewers, and
/// read-only or archived badges.
public struct SessionHeaderView: View {
  private let state: ConversationViewState
  private let showsTitle: Bool
  @Environment(\.layoutWidth) private var layoutWidth

  /// Creates the header.
  /// - Parameters:
  ///   - state: The conversation.
  ///   - showsTitle: Show the title (off when the window or navigation bar shows it).
  public init(state: ConversationViewState, showsTitle: Bool = true) {
    self.state = state
    self.showsTitle = showsTitle
  }

  /// The header.
  public var body: some View {
    let header = state.header
    let status = SessionStatusLine(state)
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Theme.Spacing.medium) {
        content(header: header, status: status, compact: false)
      }
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        HStack(spacing: Theme.Spacing.small) { primary(header: header, status: status) }
        HStack(spacing: Theme.Spacing.small) { secondary(header: header, compact: true) }
      }
    }
    .padding(.horizontal, layoutWidth == .compact ? 14 : 18)
    .padding(.vertical, Theme.Spacing.small)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("session-header")
  }

  @ViewBuilder
  private func content(header: SessionHeader, status: SessionStatusLine, compact: Bool)
    -> some View
  {
    primary(header: header, status: status)
    Spacer(minLength: 8)
    secondary(header: header, compact: compact)
  }

  @ViewBuilder
  private func primary(header: SessionHeader, status: SessionStatusLine) -> some View {
    if showsTitle {
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        Text(header.title)
          .font(.headline)
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)
        if let project = state.projectName {
          Text(project).font(Theme.Typography.section).foregroundStyle(.secondary)
        }
      }
    }
    Pill(text: status.text, systemImage: status.systemImage, tint: status.tint)
      .accessibilityIdentifier("session-status-line")
    if header.readOnly { Pill(text: "Read only", systemImage: "eye") }
    if header.archived { Pill(text: "Archived", systemImage: "archivebox") }
  }

  @ViewBuilder
  private func secondary(header: SessionHeader, compact: Bool) -> some View {
    if let settings = header.settings {
      HStack(spacing: Theme.Spacing.extraSmall) {
        HarnessGlyph(harness: settings.harness, size: 16)
        Text(settings.modelLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        "\(HarnessAppearance(harness: settings.harness).label), \(settings.modelLabel)")
    }
    if let usage = state.section("usage").map(SectionReading.usage), let fraction = usage.fraction {
      UsageGauge(usage: usage, fraction: fraction)
    }
    if let presence = state.section("presence") {
      ViewerStack(viewers: SectionReading.viewers(presence))
    }
  }
}

extension SessionStatusLine {
  /// A glyph that never suggests progress while the session waits.
  var systemImage: String {
    switch kind {
    case .waiting: "hand.raised.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .running: "circle.dotted.circle"
    case .finished: "checkmark.circle"
    case .ready: "circle"
    }
  }

  /// Pink only for "needs you".
  var tint: ThemeColor {
    switch kind {
    case .waiting: Theme.attention
    case .failed: Theme.failure
    case .running: Theme.running
    case .finished, .ready: Theme.secondary
    }
  }
}

struct UsageGauge: View {
  let usage: SectionReading.Usage
  let fraction: Double

  var body: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      ProgressRing(fraction: fraction, size: 14, warnsNearFull: true)
      Text(fraction.formatted(.percent.precision(.fractionLength(0))))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .help(helpText)
    .accessibilityElement()
    .accessibilityLabel("Context used")
    .accessibilityValue(helpText)
  }

  private var helpText: String {
    let tokens = usage.contextTokens.map { $0.formatted() } ?? "?"
    let window = usage.contextWindow.map { $0.formatted() } ?? "?"
    return "\(tokens) of \(window) context tokens"
  }
}

struct ViewerStack: View {
  let viewers: [SectionReading.Viewer]

  var body: some View {
    if !viewers.isEmpty {
      HStack(spacing: -6) {
        ForEach(viewers.prefix(4)) { viewer in
          Text(viewer.initials.isEmpty ? "?" : viewer.initials)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.extraSmall)
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color(for: viewer.name).opacity(viewer.isIdle ? 0.45 : 1), in: Circle())
            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
        }
        if viewers.count > 4 {
          Text("+\(viewers.count - 4)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, Theme.Spacing.medium)
        }
      }
      .help(viewers.map(\.name).joined(separator: ", "))
      .accessibilityElement()
      .accessibilityLabel(
        "\(viewers.count) viewers: \(viewers.map(\.name).joined(separator: ", "))")
    }
  }

  private func color(for name: String) -> Color {
    let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
    let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    return palette[hash % palette.count]
  }
}
