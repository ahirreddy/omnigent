#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Members, clicked", .serialized)
  @MainActor
  struct SettingsMembersTests {
    private let log = ActionLog()
    private let store: UserDefaults

    init() throws {
      store = try #require(UserDefaults(suiteName: "settings-members-\(UUID())"))
    }

    private var actions: ServerSettingsActions {
      var actions = ServerSettingsActions()
      let log = log
      actions.resetPassword = {
        log.record("reset \($0.id)")
        return "new-secret"
      }
      actions.removeMember = { log.record("remove \($0.id)") }
      return actions
    }

    private var member: ServerMember {
      ServerMember(
        id: "ada", detail: "Today", isAdmin: true, canResetPassword: true, canRemove: true)
    }

    @Test("Remove asks first, and only yes removes that member")
    func remove() throws {
      let actions = actions
      let member = member
      let screen = settingsForm(store: store) { MembersPane(members: [member], actions: actions) }
      defer { screen.close() }
      #expect(try screen.shows("Admin"))
      #expect(try screen.shows("Today"))
      let menu = try #require(screen.popUps.first)
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      try screen.choose("Remove\u{2026}", inPopUp: menu)
      #expect(SystemSideEffects.record.alertMessages == ["Remove ada?"])
      #expect(log.entries.isEmpty)
      SystemSideEffects.answer(alert: .alertFirstButtonReturn)
      try screen.choose("Remove\u{2026}", inPopUp: menu)
      #expect(log.entries == ["remove ada"])
    }

    @Test("a reset's new password shows once, and Copy copies that password")
    func resetCopies() async throws {
      let actions = actions
      let member = member
      let screen = settingsForm(store: store) { MembersPane(members: [member], actions: actions) }
      defer { screen.close() }
      try screen.choose("Reset Password\u{2026}", inPopUp: try #require(screen.popUps.first))
      try await screen.letTasksRun()
      #expect(log.entries == ["reset ada"])
      #expect(SystemSideEffects.record.alertMessages == ["New password for ada"])
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "new-secret")
    }

    @Test("a member with nothing this server can do to them has no menu")
    func noMenu() throws {
      var noRemove = ServerSettingsActions()
      noRemove.resetPassword = { _ in nil }
      let removable = ServerMember(id: "a", isAdmin: false, canRemove: true)
      let screen = settingsForm(store: store) {
        MembersPane(members: [removable], actions: noRemove)
      }
      defer { screen.close() }
      #expect(screen.popUps.isEmpty)
    }

    @Test("a failed reset shows no new password")
    func failedReset() async throws {
      var failing = ServerSettingsActions()
      failing.resetPassword = { _ in nil }
      let resettable = ServerMember(id: "a", isAdmin: false, canResetPassword: true)
      let screen = settingsForm(store: store) {
        MembersPane(members: [resettable], actions: failing)
      }
      defer { screen.close() }
      try screen.choose("Reset Password\u{2026}", inPopUp: try #require(screen.popUps.first))
      try await screen.letTasksRun()
      #expect(SystemSideEffects.record.alertMessages.isEmpty)
    }

    @Test("no members says so, and Invite only shows with an invite action")
    func emptyAndInvite() throws {
      let screen = settingsForm(store: store) {
        MembersPane(members: [], actions: ServerSettingsActions())
      }
      defer { screen.close() }
      #expect(try screen.shows("No members."))
      #expect(screen.controlFrames.isEmpty)
    }

    private func inviteSheet(
      link: MemberInviteLink?, errorMessage: String? = nil
    ) throws -> OffscreenWindow<some View> {
      var actions = ServerSettingsActions()
      let log = log
      actions.invite = {
        log.record("invite admin=\($0)")
        return link
      }
      let screen = settingsForm(store: store) {
        MembersPane(members: [], actions: actions, errorMessage: errorMessage)
      }
      try screen.clickControl(at: 0)
      screen.settle(0.3)
      try #require(screen.window.attachedSheet != nil)
      return screen
    }

    @Test("Create Invite sends the admin choice, then shows a link that Copy copies")
    func invite() async throws {
      let link = MemberInviteLink(url: "https://x.dev/register/abc", expiresAt: nil)
      let screen = try inviteSheet(link: link)
      defer { screen.close() }
      // The checkbox, Cancel, Create Invite.
      try screen.clickButton(at: 0)
      try screen.clickButton(at: 2)
      try await screen.letTasksRun()
      #expect(log.entries == ["invite admin=true"])
      // Copy Link, Done.
      #expect(try screen.shows(link.url))
      #expect(try screen.shows("It works once."))
      try screen.clickButton(at: 0)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == link.url)
      try screen.clickButton(at: 1)
      screen.settle(0.3)
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("a failed invite stays open to try again; Cancel closes it")
    func failedInvite() async throws {
      let screen = try inviteSheet(link: nil)
      defer { screen.close() }
      try screen.clickButton(at: 2)
      try await screen.letTasksRun()
      #expect(log.entries == ["invite admin=false"])
      #expect(screen.window.attachedSheet != nil)
      #expect(try screen.shows("The invite could not be created."))
      try screen.clickButton(at: 1)
      screen.settle(0.3)
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("a link that expires says when; the server's reason beats the generic failure")
    func expiryAndReason() async throws {
      let expiring = MemberInviteLink(url: "u", expiresAt: Date(timeIntervalSince1970: 0))
      let screen = try inviteSheet(link: expiring)
      defer { screen.close() }
      try screen.clickButton(at: 2)
      try await screen.letTasksRun()
      #expect(try screen.shows("It works once and expires"))
      let failing = try inviteSheet(link: nil, errorMessage: "Invites are off")
      defer { failing.close() }
      try failing.clickButton(at: 2)
      try await failing.letTasksRun()
      #expect(try failing.shows("Invites are off"))
    }
  }
#endif
