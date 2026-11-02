import OmnigentCoreFFI
public import SwiftUI

/// A remote browser tab on the fixture host, attached for control: for the playground, the
/// gallery and previews. Navigating to a URL containing `small` plays the 640×400 stream.
public struct RemoteBrowserFixtureTab: View {
  @State private var store: RemoteBrowserStore

  /// Creates the tab.
  /// - Parameters:
  ///   - id: The fixture tab id; tabs with the same id share a page.
  ///   - url: The first page.
  public init(id: String = "btab_fixture", url: String = "https://example.com/") {
    FixtureRemoteBrowser.shared.addTab(id: id, url: url)
    _store = State(initialValue: RemoteBrowserStore(sessionID: "fixture", tabID: id))
  }

  /// The view body.
  public var body: some View {
    RemoteBrowserTabView(store: store)
      .task { store.attach(using: FixtureRemoteBrowser.shared, mode: .control, hostID: nil) }
  }
}
