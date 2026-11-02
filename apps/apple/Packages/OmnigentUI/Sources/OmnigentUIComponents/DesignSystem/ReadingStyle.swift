import SwiftUI

struct ProseStyle: ViewModifier {
  @ScaledMetric(relativeTo: .body) private var size = Theme.Typography.proseSize
  @ScaledMetric(relativeTo: .body) private var leading = Theme.Typography.leading

  func body(content: Content) -> some View {
    content.font(.system(size: size)).lineSpacing(leading)
  }
}

struct ComposerChip: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(Theme.Typography.label)
      .padding(.horizontal, Theme.Spacing.extraSmall)
      .frame(minWidth: Theme.Control.target, minHeight: Theme.Control.target)
      .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
      .hoverHighlight()
  }
}

extension View {
  /// The transcript, dock and composer share their outside edges: the configured
  /// ``TranscriptContentWidth`` (a reading column by default).
  func readingColumn() -> some View { transcriptColumn() }
  func proseStyle() -> some View { modifier(ProseStyle()) }
  func composerChip() -> some View { modifier(ComposerChip()) }
}
