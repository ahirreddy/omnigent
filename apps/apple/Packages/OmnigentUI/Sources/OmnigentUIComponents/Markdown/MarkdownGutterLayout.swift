import SwiftUI

/// A list marker or quote rule beside its content. An `HStack` probes nested content at several
/// widths per level, so its cost multiplies with depth and a few nested lists hang the main
/// thread; this asks each level for one size.
struct MarkdownGutterLayout: Layout {
  enum Gutter {
    /// A marker sharing its first text baseline with the content.
    case baselineMarker
    /// A rule as tall as the content.
    case fullHeightRule
  }

  let gutter: Gutter
  let spacing: CGFloat

  private struct Arrangement {
    let gutterProposal: ProposedViewSize
    let contentProposal: ProposedViewSize
    let gutterTop: CGFloat
    let contentTop: CGFloat
    let contentLeading: CGFloat
    let contentBaseline: CGFloat?
    let size: CGSize
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
    arrangement(for: proposal, subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
  ) {
    let arranged = arrangement(for: proposal, subviews)
    guard subviews.count == 2 else { return }
    subviews[0].place(
      at: CGPoint(x: bounds.minX, y: bounds.minY + arranged.gutterTop),
      proposal: arranged.gutterProposal)
    subviews[1].place(
      at: CGPoint(x: bounds.minX + arranged.contentLeading, y: bounds.minY + arranged.contentTop),
      proposal: arranged.contentProposal)
  }

  /// A list whose item opens with another list still lines its markers up on that first line.
  func explicitAlignment(
    of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
    cache: inout Void
  ) -> CGFloat? {
    guard guide == .firstTextBaseline else { return nil }
    let arranged = arrangement(for: proposal, subviews)
    return arranged.contentBaseline.map { bounds.minY + arranged.contentTop + $0 }
  }

  private func arrangement(for proposal: ProposedViewSize, _ subviews: Subviews) -> Arrangement {
    guard subviews.count == 2 else {
      return Arrangement(
        gutterProposal: .unspecified, contentProposal: .unspecified, gutterTop: 0, contentTop: 0,
        contentLeading: 0, contentBaseline: nil, size: .zero)
    }
    let gutterWidth = subviews[0].sizeThatFits(.unspecified).width
    let contentLeading = gutterWidth + spacing
    let contentProposal = ProposedViewSize(
      width: proposal.width.map { max($0 - contentLeading, 0) }, height: nil)
    let content = subviews[1].dimensions(in: contentProposal)
    let contentBaseline = content[.firstTextBaseline]
    let width = contentLeading + content.width
    switch gutter {
    case .fullHeightRule:
      return Arrangement(
        gutterProposal: ProposedViewSize(width: gutterWidth, height: content.height),
        contentProposal: contentProposal, gutterTop: 0, contentTop: 0,
        contentLeading: contentLeading, contentBaseline: contentBaseline,
        size: CGSize(width: width, height: content.height))
    case .baselineMarker:
      let marker = subviews[0].dimensions(in: .unspecified)
      let gutterBaseline = marker[.firstTextBaseline]
      let gutterTop = max(contentBaseline - gutterBaseline, 0)
      let contentTop = max(gutterBaseline - contentBaseline, 0)
      let height = max(gutterTop + marker.height, contentTop + content.height)
      return Arrangement(
        gutterProposal: .unspecified, contentProposal: contentProposal, gutterTop: gutterTop,
        contentTop: contentTop, contentLeading: contentLeading,
        contentBaseline: contentBaseline, size: CGSize(width: width, height: height))
    }
  }
}
