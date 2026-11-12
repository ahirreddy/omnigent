import SwiftUI

/// Shows content by its height: from none of it to all of it, clipped at the moving edge, so
/// what is below travels the whole way with it instead of jumping.
struct RevealLayout: Layout {
  /// How much of the content's height shows, from 0 to 1.
  var progress: CGFloat

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let content = subviews.first else { return .zero }
    let size = content.sizeThatFits(proposal)
    return CGSize(width: size.width, height: size.height * progress)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    subviews.first?.place(
      at: bounds.origin, anchor: .topLeading,
      proposal: ProposedViewSize(width: bounds.width, height: nil))
  }
}

private struct Reveal: ViewModifier {
  let progress: CGFloat

  func body(content: Content) -> some View {
    RevealLayout(progress: progress) { content }
      .clipped()
      .opacity(progress)
  }
}

extension AnyTransition {
  /// Opens downward from the top edge and closes back up to it, a little at a time.
  static var reveal: AnyTransition {
    .modifier(active: Reveal(progress: 0), identity: Reveal(progress: 1))
  }
}
