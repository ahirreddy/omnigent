import Foundation
import SwiftUI

@testable import OmnigentUIComponents

/// Generic data for an extension's page and its sidebar entry.
@MainActor
extension SweepLookFixtures {
  /// An extension's page that could not start, or a link to a page no extension has.
  static func extensionPage(found: Bool) -> some View {
    let state =
      found
      ? PreviewData.extensionPage
      : ExtensionPageState(title: "Page not found", phase: .notFound)
    return ExtensionPageView(state: state, channel: ExtensionFrameChannel(), actions: .inert)
  }

  /// The sidebar with an extension's entry between Canvas and Usage, its page open.
  static var extensionSidebar: some View {
    var state = PreviewData.sidebar
    state.extensionEntries = [PreviewData.extensionEntry]
    return SidebarView(
      state: state, selection: .constant(PreviewData.extensionEntry.destination),
      searchText: .constant(""), actions: GalleryActions.sidebar { _ in })
  }
}
