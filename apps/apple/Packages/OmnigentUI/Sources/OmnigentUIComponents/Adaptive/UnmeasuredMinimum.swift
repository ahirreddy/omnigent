import SwiftUI

extension View {
  /// On Mac, gives the view a fixed minimum size without measuring it (``UnmeasuredMinimum``),
  /// for the root of a split view column or inspector, whose hosting controller would otherwise
  /// measure the whole view on every update. Elsewhere the view is unchanged.
  /// - Parameter minimum: The size reported for zero and unspecified proposals.
  /// - Returns: The view.
  @ViewBuilder func unmeasuredMinimum(_ minimum: CGSize) -> some View {
    #if os(macOS)
      UnmeasuredMinimum(minimum: minimum) { self }
    #else
      self
    #endif
  }
}

/// Reports a fixed minimum size for small proposals without measuring its child.
///
/// A split view column's hosting controller (NavigationSplitView's detail, `.inspector`'s main
/// content) asks its root for the sizes that fit a zero and an unbounded proposal after every
/// update, to keep its constraints current. That measured the whole conversation (composer,
/// transcript, banners) on every streamed delta. This layout answers from `minimum` and only
/// measures the child to place it. The window's root does the same (`WindowMinimumSize`).
struct UnmeasuredMinimum: Layout {
  /// A conversation column's minimum on Mac: with the narrowest sidebar and right panel it
  /// still fits the smallest window.
  static let column = CGSize(width: 240, height: 200)

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
