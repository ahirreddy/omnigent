import SwiftUI

/// The transcript, dock and composer share their outside edges.
struct ReadingColumn: ViewModifier {
  @Environment(\.layoutWidth) private var layoutWidth

  func body(content: Content) -> some View {
    content
      .frame(minWidth: 0, maxWidth: Theme.transcriptWidth, alignment: .leading)
      .padding(
        .horizontal, layoutWidth == .compact ? Theme.Spacing.compactGutter : Theme.Spacing.gutter
      )
      .frame(minWidth: 0, maxWidth: .infinity)
  }
}

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
  func readingColumn() -> some View { modifier(ReadingColumn()) }
  func proseStyle() -> some View { modifier(ProseStyle()) }
  func composerChip() -> some View { modifier(ComposerChip()) }
}
