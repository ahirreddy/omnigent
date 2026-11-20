import Testing

@testable import OmnigentUIComponents

/// The editor's Timezone menu, as the web's list: UTC first, then by region.
@Suite("Automation time zones")
struct AutomationTimeZoneTests {
  @Test("UTC and this device's zone lead, once each")
  func leading() {
    #expect(
      AutomationTimeZonePicker.leading(current: "America/New_York") == ["UTC", "America/New_York"])
    #expect(AutomationTimeZonePicker.leading(current: "UTC") == ["UTC"])
  }

  @Test("Zones group by region, sorted, and read with spaces")
  func regions() {
    let regions = AutomationTimeZonePicker.regions([
      "Europe/Paris", "America/New_York", "UTC", "America/Chicago", "Asia/Tokyo",
    ])
    #expect(regions.map(\.name) == ["America", "Asia", "Europe"])
    #expect(regions.first?.zones == ["America/Chicago", "America/New_York"])
    #expect(AutomationTimeZonePicker.label("America/New_York") == "America/New York")
  }
}
