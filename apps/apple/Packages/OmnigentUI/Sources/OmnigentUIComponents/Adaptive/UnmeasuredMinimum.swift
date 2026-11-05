import SwiftUI

/// Reports a fixed minimum size for small proposals without measuring its child.
///
/// A split view column's hosting controller asks its root for the sizes that fit a zero and an
/// unbounded proposal after every update, to keep its constraints current. For the detail column
/// that measured the whole conversation (composer, transcript, banners) on every streamed delta.
/// This layout answers from `minimum` and only measures the child to place it. The window's own
/// root does the same through `WindowMinimumSize` (OmnigentDesktop).
struct UnmeasuredMinimum: Layout {
  let minimum: CGSize

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    Self.size(for: proposal, minimum: minimum)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for subview in subviews {
      subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
  }

  /// The proposal with unspecified dimensions read as the minimum, never below it.
  static func size(for proposal: ProposedViewSize, minimum: CGSize) -> CGSize {
    CGSize(
      width: max(minimum.width, proposal.width ?? minimum.width),
      height: max(minimum.height, proposal.height ?? minimum.height))
  }
}
