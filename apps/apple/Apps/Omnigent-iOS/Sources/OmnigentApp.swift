import OmnigentStores
import OmnigentUI
import SwiftUI

@main
struct OmnigentApp: App {
  @State private var connection = ConnectionStore()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(connection)
    }
  }
}
