import OWLProtocol
import Testing

/// The Chromium switches the host runs its browser process with (owl_chromium.h).
@Suite("Host command line")
struct HostCommandLineTests {
  private let disabled = OWL_CHROMIUM_DISABLED_FEATURES.split(separator: ",")

  /// Neither the host nor its helper asks macOS for notification permission at launch.
  @Test func theHostNeverAsksForNotificationPermission() {
    #expect(disabled.contains("SystemNotifications"))
  }

  /// CEF helpers cannot run Chrome's code sign clone cleanup, so the clone stays off.
  @Test func theHostMakesNoCodeSignClone() {
    #expect(disabled.contains("MacAppCodeSignClone"))
  }
}
