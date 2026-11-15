public import SwiftUI

/// The tabs along the top of a `Settings` scene's window, each at the form width.
public struct SettingsTabWindow: View {
  let tabs: [SettingsTabItem]
  @Binding var selection: String

  /// The tabs.
  public var body: some View {
    TabView(selection: $selection) {
      ForEach(tabs) { item in
        Tab(item.title, systemImage: item.systemImage, value: item.id) {
          item.content.frame(width: item.isWide ? nil : Self.formWidth)
        }
      }
    }
    .scenePadding()
    // The window takes the content's minimum, so this keeps General and Appearance unclipped.
    .frame(minHeight: Self.formHeight)
  }

  /// The width of the form tabs; a wide tab (``SettingsTabItem/isWide``) sizes itself.
  static var formWidth: CGFloat { 580 }

  /// The tabs' least height: tall enough that General and Appearance show their groups; each
  /// form scrolls within it.
  static var formHeight: CGFloat { 680 }
}
