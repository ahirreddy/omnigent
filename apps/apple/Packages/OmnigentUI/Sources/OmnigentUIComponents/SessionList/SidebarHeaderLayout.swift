import SwiftUI

/// The sidebar header's row: the wordmark at the leading edge, the buttons at the trailing edge
/// and the server name just before them. When the name doesn't fit beside the wordmark (a narrow
/// iPad sidebar, a long host) it moves to its own line under the wordmark instead of truncating.
/// Subviews: the wordmark, then the server name if shown, then the buttons.
struct SidebarHeaderLayout: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let width = proposal.width ?? Self.rowWidth(sizes, spacing: spacing)
    let firstRow = max(sizes.first?.height ?? 0, sizes.last?.height ?? 0)
    guard let name = Self.nameSize(sizes), !Self.fitsOneRow(sizes, width: width, spacing: spacing)
    else {
      return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }
    return CGSize(width: width, height: firstRow + spacing + name.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    guard let wordmark = subviews.first, let buttons = subviews.last, subviews.count > 1 else {
      subviews.first?.place(at: bounds.origin, proposal: proposal)
      return
    }
    let oneRow = Self.fitsOneRow(sizes, width: bounds.width, spacing: spacing)
    let rowHeight = oneRow ? bounds.height : max(sizes[0].height, sizes[sizes.count - 1].height)
    wordmark.place(
      at: CGPoint(x: bounds.minX, y: bounds.minY + rowHeight / 2), anchor: .leading,
      proposal: ProposedViewSize(sizes[0]))
    buttons.place(
      at: CGPoint(x: bounds.maxX, y: bounds.minY + rowHeight / 2), anchor: .trailing,
      proposal: ProposedViewSize(sizes[sizes.count - 1]))
    guard subviews.count == 3 else { return }
    let name = sizes[1]
    if oneRow {
      let trailing = bounds.maxX - sizes[2].width - spacing
      subviews[1].place(
        at: CGPoint(x: trailing, y: bounds.minY + rowHeight / 2), anchor: .trailing,
        proposal: ProposedViewSize(name))
    } else {
      subviews[1].place(
        at: CGPoint(x: bounds.minX, y: bounds.minY + rowHeight + spacing), anchor: .topLeading,
        proposal: ProposedViewSize(width: min(name.width, bounds.width), height: name.height))
    }
  }

  private static func nameSize(_ sizes: [CGSize]) -> CGSize? {
    sizes.count == 3 ? sizes[1] : nil
  }

  private static func rowWidth(_ sizes: [CGSize], spacing: CGFloat) -> CGFloat {
    sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
  }

  /// Whether everything fits on one line at its ideal width.
  static func fitsOneRow(_ sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> Bool {
    rowWidth(sizes, spacing: spacing) <= width
  }
}
