#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Sharing, clicked", .serialized)
  @MainActor
  struct SettingsSharingTests {
    private let log = ActionLog()
    private let store: UserDefaults

    init() throws {
      store = try #require(UserDefaults(suiteName: "settings-sharing-\(UUID())"))
    }

    private var actions: ServerSettingsActions {
      var actions = ServerSettingsActions()
      let log = log
      actions.changeSharing = { log.record("\($0)") }
      return actions
    }

    private func sharing(
      mode: String = "on", isPublic: Bool = true, editable: Bool = true
    ) -> SharingViewState {
      let modes = ["on", "read_only", "restricted_read_only", "off"].map {
        SettingChoice(id: $0, title: "Mode \($0)")
      }
      return SharingViewState(
        mode: mode, modeChoices: modes, modeEditable: editable, publicSharing: isPublic,
        publicSharingEditable: editable, publicLevel: "read",
        publicLevelChoices: [
          SettingChoice(id: "read", title: "Read"), SettingChoice(id: "edit", title: "Edit"),
        ], publicLevelEditable: editable, defaultPublic: "none",
        defaultPublicChoices: [
          SettingChoice(id: "none", title: "No"), SettingChoice(id: "read", title: "Yes"),
        ], defaultPublicEditable: editable)
    }

    private func screen(_ sharing: SharingViewState?) -> OffscreenWindow<some View> {
      let actions = actions
      return settingsForm(store: store) { SharingPane(sharing: sharing, actions: actions) }
    }

    @Test("each control sends its own change")
    func changes() throws {
      let screen = screen(sharing())
      defer { screen.close() }
      try screen.choose(
        "Mode off", inPopUp: try #require(screen.popUps.first { $0.title == "Mode on" }))
      try screen.click(try #require(screen.switches.first))
      try screen.choose("Edit", inPopUp: try #require(screen.popUps.first { $0.title == "Read" }))
      try screen.choose("Yes", inPopUp: try #require(screen.popUps.first { $0.title == "No" }))
      #expect(
        log.entries == [
          "\(SharingChange.mode("off"))", "\(SharingChange.publicSharing(false))",
          "\(SharingChange.publicLevel("edit"))", "\(SharingChange.defaultPublic("read"))",
        ])
    }

    @Test("sharing off explains why public controls can't change")
    func sharingOff() throws {
      let screen = screen(sharing(mode: "off"))
      defer { screen.close() }
      #expect(try screen.shows("Turn sharing on to use public access."))
      #expect(try screen.shows("Turn sharing on to change the default visibility."))
      let toggle = try #require(screen.switches.first)
      #expect(!toggle.isEnabled)
      #expect(
        (toggle as? NSSwitch)?.state == .off, "off, even though the server says public is allowed")
    }

    @Test("public access off blocks the default; a managed deployment says so")
    func blockedAndManaged() throws {
      let blocked = screen(sharing(isPublic: false))
      defer { blocked.close() }
      #expect(try blocked.shows("Turn on public access to change the default visibility."))
      #expect(blocked.popUps.first { $0.title == "No" }?.isEnabled == false)
      let managed = screen(sharing(editable: false))
      defer { managed.close() }
      #expect(try managed.shows("Managed by this deployment"))
      #expect(managed.popUps.allSatisfy { !$0.isEnabled })
    }

    @Test("every tier has its explanation; an unknown tier has none")
    func tiers() {
      for mode in ["on", "read_only", "restricted_read_only", "off"] {
        #expect(SharingPane.tierDescription(mode)?.isEmpty == false, "\(mode)")
      }
      #expect(SharingPane.tierDescription("mystery") == nil)
    }

    @Test("nothing loaded yet shows nothing")
    func notLoaded() throws {
      let screen = screen(nil)
      defer { screen.close() }
      #expect(try !screen.shows("Session sharing"))
    }
  }
#endif
