import OmnigentCoreFFI
public import SwiftUI

/// App preferences (the macOS Settings scene).
public struct SettingsView: View {
  @AppStorage(OmnigentDefaults.serverURLKey) private var serverURL = OmnigentDefaults
    .defaultServerURL

  /// Creates the settings form.
  public init() {}

  /// The form.
  public var body: some View {
    Form {
      Section("Server") {
        TextField("Default server URL", text: $serverURL)
          .accessibilityIdentifier("settings.serverURL")
        Button("Restore Default") { serverURL = OmnigentDefaults.defaultServerURL }
          .disabled(serverURL == OmnigentDefaults.defaultServerURL)
      }
      Section("About") {
        LabeledContent("Core version", value: coreVersion())
      }
    }
    .formStyle(.grouped)
    #if os(macOS)
      .frame(width: 460)
      .fixedSize(horizontal: false, vertical: true)
    #endif
  }
}
