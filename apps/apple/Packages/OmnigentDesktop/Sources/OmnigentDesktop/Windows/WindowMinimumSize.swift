public import SwiftUI

/// Gives a window a fixed minimum size without measuring its content.
///
/// With `.windowResizability(.contentMinSize)` the hosting view asks the root for its size at a
/// zero proposal after every layout change. Through a `.frame(minWidth:minHeight:)` that measures
/// the whole window (sidebar, toolbar, transcript) on every streamed delta. This layout answers
/// that question from `minimum` alone and only measures the content to place it.
public struct WindowMinimumSize<Content: View>: View {
  private let minimum: CGSize
  private let content: Content

  /// Wraps `content`.
  /// - Parameters:
  ///   - minimum: The window's minimum content size.
  ///   - content: The window's content.
  public init(_ minimum: CGSize, @ViewBuilder content: () -> Content) {
    self.minimum = minimum
    self.content = content()
  }

  /// The content in a layout that reports `minimum` for small proposals.
  public var body: some View {
    MinimumSizeLayout(minimum: minimum) { content }
  }
}

/// Reports the proposal clamped to `minimum`, without asking its child.
struct MinimumSizeLayout: Layout {
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
