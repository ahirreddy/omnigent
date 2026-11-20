import Foundation
import SwiftUI

/// The schedule's Timezone row (the web's timezone combobox): UTC and this device's zone first,
/// then every zone by region, as submenus.
struct AutomationTimeZonePicker: View {
  @Binding var timezone: String

  var body: some View {
    LabeledContent("Timezone") {
      Menu(Self.label(timezone)) {
        let top = Self.leading(current: TimeZone.current.identifier)
        ForEach(top, id: \.self) { zone in choice(zone, title: Self.label(zone)) }
        Divider()
        ForEach(Self.regions(TimeZone.knownTimeZoneIdentifiers), id: \.name) { region in
          Menu(region.name) {
            ForEach(region.zones, id: \.self) { zone in
              choice(zone, title: Self.label(String(zone.dropFirst(region.name.count + 1))))
            }
          }
        }
      }
      .fixedSize()
      .accessibilityIdentifier("automation-timezone")
    }
  }

  private func choice(_ zone: String, title: String) -> some View {
    Button {
      timezone = zone
    } label: {
      if zone == timezone {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }

  /// A zone as the web shows it: "America/New York".
  static func label(_ zone: String) -> String {
    zone.replacingOccurrences(of: "_", with: " ")
  }

  /// UTC, then this device's zone when it is another.
  static func leading(current: String) -> [String] {
    current == "UTC" || current.isEmpty ? ["UTC"] : ["UTC", current]
  }

  /// The zones grouped by their region ("Africa", "America"), each sorted; zones without a
  /// region ("UTC") are left to the top of the menu.
  static func regions(_ zones: [String]) -> [(name: String, zones: [String])] {
    let grouped = Dictionary(grouping: zones.filter { $0.contains("/") }) {
      String($0.prefix { $0 != "/" })
    }
    return grouped.keys.sorted().map { (name: $0, zones: (grouped[$0] ?? []).sorted()) }
  }
}
