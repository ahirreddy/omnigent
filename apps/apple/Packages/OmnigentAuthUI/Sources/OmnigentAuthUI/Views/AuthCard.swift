public import SwiftUI

/// Layout metrics shared by the sign-in screens.
enum AuthMetrics {
  /// The card's width in a desktop window or sheet.
  static let cardWidth: CGFloat = 440
  static let cardPadding: CGFloat = 28
  static let compactPadding: CGFloat = 20
  static let sectionSpacing: CGFloat = 18
  static let radius: CGFloat = 12
  static let fieldSpacing: CGFloat = 6
}

/// The common frame of a sign-in screen: an icon, a title, optional subtitle, the content, and a
/// button row laid out by ``AuthButtonRow``.
struct AuthCard<Content: View, Buttons: View>: View {
  let systemImage: String
  let title: String
  var subtitle: String?
  var isProgress = false
  @ViewBuilder var content: Content
  @ViewBuilder var buttons: Buttons

  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    VStack(alignment: .leading, spacing: AuthMetrics.sectionSpacing) {
      header
      content
      buttonRow
    }
    .frame(maxWidth: AuthMetrics.cardWidth, alignment: .leading)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      Group {
        if isProgress {
          ProgressView()
            .controlSize(.large)
            .accessibilityLabel(title)
        } else {
          Image(systemName: systemImage)
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(.tint)
            .symbolRenderingMode(.hierarchical)
            .accessibilityHidden(true)
        }
      }
      .frame(height: 36)
      Text(title)
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      if let subtitle {
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var buttonRow: some View {
    AuthButtonRow(stacked: sizeClass == .compact) {
      buttons
    }
    .environment(\.authButtonLayout, sizeClass == .compact ? .stacked : .row)
  }
}

/// How ``AuthButton``s lay out in a card's button row.
enum AuthButtonLayout {
  case row
  case stacked
}

extension EnvironmentValues {
  @Entry var authButtonLayout = AuthButtonLayout.row
}

/// Orders a card's buttons by role. A row (desktop) is trailing-aligned with the primary button
/// rightmost; a stack (compact) is full width with the primary button on top.
struct AuthButtonRow: Layout {
  var stacked: Bool
  var spacing: CGFloat = 10

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let ordered = order(subviews)
    if stacked {
      let width = proposal.width ?? ordered.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
      let heights = ordered.map {
        $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
      }
      return CGSize(width: width, height: heights.reduce(0, +) + gaps(ordered.count))
    }
    let sizes = ordered.map { $0.sizeThatFits(.unspecified) }
    let width = sizes.map(\.width).reduce(0, +) + gaps(ordered.count)
    return CGSize(width: proposal.width ?? width, height: sizes.map(\.height).max() ?? 0)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let ordered = order(subviews)
    if stacked {
      var top = bounds.minY
      for subview in ordered {
        let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subview.place(
          at: CGPoint(x: bounds.minX, y: top), anchor: .topLeading,
          proposal: ProposedViewSize(width: bounds.width, height: size.height))
        top += size.height + spacing
      }
      return
    }
    var trailing = bounds.maxX
    for subview in ordered.reversed() {
      let size = subview.sizeThatFits(.unspecified)
      subview.place(
        at: CGPoint(x: trailing, y: bounds.midY), anchor: .trailing,
        proposal: ProposedViewSize(size))
      trailing -= size.width + spacing
    }
  }

  private func order(_ subviews: Subviews) -> [LayoutSubview] {
    let primary = subviews.filter { $0[AuthButtonKindKey.self] == .primary }
    let others = subviews.filter { $0[AuthButtonKindKey.self] != .primary }
    return stacked ? primary + others : others + primary
  }

  private func gaps(_ count: Int) -> CGFloat {
    CGFloat(max(count - 1, 0)) * spacing
  }
}

private nonisolated struct AuthButtonKindKey: LayoutValueKey {
  static let defaultValue = AuthButtonKind.secondary
}

/// A card button's role.
nonisolated enum AuthButtonKind: Hashable, Sendable {
  /// The default button.
  case primary
  /// The cancel button.
  case cancel
  /// Any other button.
  case secondary
}

/// A card button. The default button is prominent and answers Return; the cancel button answers
/// Escape (Command-period on the Mac).
struct AuthButton: View {
  let title: String
  var kind = AuthButtonKind.secondary
  var isBusy = false
  var identifier: String
  let action: () -> Void

  @Environment(\.authButtonLayout) private var layout

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if isBusy {
          ProgressView().controlSize(.small)
        }
        Text(title)
      }
      .frame(maxWidth: layout == .stacked ? .infinity : nil)
      .padding(.horizontal, layout == .row ? 6 : 0)
    }
    .controlSize(.large)
    .modifier(AuthButtonStyle(kind: kind))
    .accessibilityIdentifier(identifier)
    .layoutValue(key: AuthButtonKindKey.self, value: kind)
  }
}

private struct AuthButtonStyle: ViewModifier {
  let kind: AuthButtonKind

  func body(content: Content) -> some View {
    switch kind {
    case .primary:
      content
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    case .cancel:
      content
        .buttonStyle(.bordered)
        .keyboardShortcut(.cancelAction)
    case .secondary:
      content
        .buttonStyle(.bordered)
    }
  }
}

/// The server a screen is about: its name, host, version and sign-in mode.
struct ServerSummary: View {
  let server: ServerIdentity

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "server.rack")
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 32, height: 32)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: server.displayName)
          .font(.headline)
          .lineLimit(1)
        Text(verbatim: details)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: AuthMetrics.radius))
    .overlay {
      RoundedRectangle(cornerRadius: AuthMetrics.radius)
        .strokeBorder(.separator, lineWidth: 0.5)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
    .accessibilityIdentifier("auth.server-summary")
  }

  private var details: String {
    var parts: [String] = []
    if server.displayName != server.hostLabel { parts.append(server.hostLabel) }
    if let version = server.serverVersion, !version.isEmpty {
      parts.append("v\(ServerText.escaped(version, limit: 32))")
    }
    if let mode = server.mode { parts.append(mode.displayName) }
    return parts.isEmpty ? server.hostLabel : parts.joined(separator: " \u{00B7} ")
  }

  private var accessibilityText: String {
    "Server \(server.displayName), \(details)"
  }
}

/// Places a screen in its presentation: centered in a window, or sized for a sheet.
struct AuthContainer<Content: View>: View {
  let presentation: AuthPresentation
  @ViewBuilder var content: Content

  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    switch presentation {
    case .window:
      GeometryReader { proxy in
        ScrollView {
          content
            .padding(padding)
            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
        }
        .scrollBounceBehavior(.basedOnSize)
      }
    case .sheet:
      content
        .padding(padding)
        #if os(macOS)
          .frame(width: sizeClass == .compact ? nil : AuthMetrics.cardWidth + 2 * padding)
        #endif
    }
  }

  private var padding: CGFloat {
    sizeClass == .compact ? AuthMetrics.compactPadding : AuthMetrics.cardPadding
  }
}

/// Where the sign-in UI is shown.
public enum AuthPresentation: Hashable, Sendable {
  /// Centered in a window or a full-screen view.
  case window
  /// In a sheet: a fixed card width on the Mac, the sheet's width elsewhere.
  case sheet
}
