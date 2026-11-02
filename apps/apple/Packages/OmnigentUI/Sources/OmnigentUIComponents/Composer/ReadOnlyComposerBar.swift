import SwiftUI

/// The touch composer of a session that can't take messages (read-only, archived or closed): the
/// reason in place of a field that could never send.
struct ReadOnlyComposerBar: View {
  let reason: String?
  /// The CLI band's font and colors, when the transcript uses CLI style.
  var isCLI = false

  @Environment(\.cliPalette) private var palette

  var body: some View {
    Label {
      Text(reason ?? "This session is read-only.")
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "lock").accessibilityHidden(true)
    }
    .modifier(ReadOnlyText(isCLI: isCLI))
    .foregroundStyle(isCLI ? AnyShapeStyle(palette.placeholder.color) : AnyShapeStyle(.secondary))
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, minHeight: Theme.Control.target)
    .padding(.vertical, ComposerBarMetrics.outerPadding)
    .readingColumn()
    .background { if isCLI { palette.composerBand.color } }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("composer-read-only")
  }
}

private struct ReadOnlyText: ViewModifier {
  let isCLI: Bool

  func body(content: Content) -> some View {
    if isCLI {
      content.cliFont()
    } else {
      content.font(.footnote)
    }
  }
}
