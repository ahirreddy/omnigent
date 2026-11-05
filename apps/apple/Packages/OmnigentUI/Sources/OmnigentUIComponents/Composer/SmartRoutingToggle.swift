import SwiftUI

/// Smart Routing at the top of the model menu, as on the web: a checkable row with a separator
/// under it, shown only where the server and session allow routing. While it is on the router
/// picks the model and effort each turn; choosing a model turns it off.
struct SmartRoutingToggle: View {
  let configuration: ComposerConfiguration
  let set: (@MainActor (Bool) -> Void)?

  var body: some View {
    if configuration.smartRouting != .unavailable, let set {
      Section {
        Toggle(
          isOn: Binding(get: { configuration.isSmartRoutingOn }, set: { set($0) })
        ) {
          Label(ComposerConfiguration.smartRoutingTitle, systemImage: "wand.and.sparkles")
          Text("Picks the model and effort for each turn")
        }
        .accessibilityIdentifier("composer-smart-routing")
      }
    }
  }
}
