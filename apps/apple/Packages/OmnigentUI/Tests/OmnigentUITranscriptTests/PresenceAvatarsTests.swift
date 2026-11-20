import Testing

@testable import OmnigentUIComponents

/// The toolbar's presence avatars, as the web's: everyone but the viewer, with email initials.
@Suite("Presence avatars")
struct PresenceAvatarsTests {
  private func viewer(_ name: String, idle: Bool = false) -> SectionReading.Viewer {
    SectionReading.Viewer(id: name, name: name, isIdle: idle)
  }

  @Test("The viewer's own presence is left out")
  func others() {
    let viewers = [viewer("ada@example.com"), viewer("bob@example.com", idle: true)]
    #expect(
      PresenceAvatars.others(viewers, selfName: "ada@example.com").map(\.name)
        == ["bob@example.com"])
    #expect(PresenceAvatars.others(viewers, selfName: nil).count == 2)
  }

  @Test("Initials come from an email's local part, as the web's")
  func initials() {
    #expect(viewer("alice.smith@example.com").initials == "AS")
    #expect(viewer("bob@example.com").initials == "B")
    #expect(viewer("carol_ann-lee+tag@example.com").initials == "CA")
    #expect(viewer("Dana Scott").initials == "DS")
  }
}
