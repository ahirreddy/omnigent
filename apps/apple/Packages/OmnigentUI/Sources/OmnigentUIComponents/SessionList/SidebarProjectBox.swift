import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Where a row sits in its project's box: the folder's row opens it, the folder's last row
/// closes it, and a collapsed folder's row is the whole box.
enum SidebarBoxPart: Hashable {
  case top
  case middle
  case bottom
  case single

  /// The box starts at this row's top.
  var opens: Bool { self == .top || self == .single }
  /// The box ends at this row's bottom.
  var closes: Bool { self == .bottom || self == .single }
}

/// A project's box around its folder's row and everything listed in it, so a project reads as a
/// group without indenting its sessions: a source list's grouping on the Mac, an inset-grouped
/// section on iPhone and iPad.
enum SidebarBoxMetrics {
  /// Between a box's edge and a selected or hovered row inside it.
  static let padding = Theme.Spacing.extraSmall
  /// Between a box and the rows above and below it.
  static let gap = Theme.Spacing.tiny
  #if os(macOS)
    /// From the list's row edges to the box: a selection's own inset, less the padding.
    static let inset = Theme.Spacing.medium - padding
    /// The box's corners, around a selection's.
    static let radius = Theme.Radius.small + padding
    /// A source list's grouping: the system's faintest fill inside a separator hairline.
    static let fill = Color(nsColor: .quaternarySystemFill)
    static let edge: Color? = Color(nsColor: .separatorColor)
  #else
    // The system's own sidebar selection is the full row; the box takes its place.
    static let inset: CGFloat = 0
    static let radius = Theme.Radius.large
    /// An inset-grouped section's fill, with no border.
    static let fill = Color(uiColor: .quaternarySystemFill)
    static let edge: Color? = nil
  #endif
}

/// One row's part of its project's box: each row of the outline draws its own, and together they
/// read as one box with rounded ends.
struct SidebarProjectBox: View {
  let part: SidebarBoxPart

  var body: some View {
    let top = part.opens ? SidebarBoxMetrics.radius : 0
    let bottom = part.closes ? SidebarBoxMetrics.radius : 0
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
      topTrailingRadius: top, style: .continuous)
    // The hairline's open ends reach past the row, so rows above and below continue its sides.
    let reach = SidebarBoxMetrics.radius
    shape.fill(SidebarBoxMetrics.fill)
      .overlay {
        if let edge = SidebarBoxMetrics.edge {
          shape.strokeBorder(edge, lineWidth: 1)
            .padding(.top, part.opens ? 0 : -reach)
            .padding(.bottom, part.closes ? 0 : -reach)
        }
      }
      .clipped()
      .padding(.horizontal, SidebarBoxMetrics.inset)
      .padding(.top, part.opens ? SidebarBoxMetrics.gap : 0)
      .padding(.bottom, part.closes ? SidebarBoxMetrics.gap : 0)
      .accessibilityHidden(true)
  }
}
