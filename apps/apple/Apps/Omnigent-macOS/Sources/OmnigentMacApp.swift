import OmnigentStores
import OmnigentUI
import SwiftUI

@main
struct OmnigentMacApp: App {
  static let mainWindowID = "main"

  @State private var connection = ConnectionStore()

  var body: some Scene {
    WindowGroup("Omnigent", id: Self.mainWindowID) {
      RootView()
        .environment(connection)
        .frame(minWidth: 760, minHeight: 480)
    }
    .defaultSize(width: 1180, height: 760)
    .windowToolbarStyle(.unified)
    .commands {
      SidebarCommands()
      ToolbarCommands()
      OmnigentCommands(connection: connection)
    }

    Settings {
      SettingsView()
    }
  }
}

struct OmnigentCommands: Commands {
  let connection: ConnectionStore
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Window") {
        openWindow(id: OmnigentMacApp.mainWindowID)
      }
      .keyboardShortcut("n", modifiers: .command)
    }
    CommandMenu("Server") {
      Button("Reconnect") {
        Task { await connection.discover(serverURL: OmnigentDefaults.serverURL) }
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(connection.isLoading)
    }
  }
}
