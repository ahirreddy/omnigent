#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Account and password, clicked", .serialized)
  @MainActor
  struct SettingsAccountTests {
    private let log = ActionLog()
    private let store: UserDefaults

    init() throws {
      store = try #require(UserDefaults(suiteName: "settings-account-\(UUID())"))
    }

    private func fill<Content>(
      _ screen: OffscreenWindow<Content>, current: String, new: String, confirmation: String
    ) throws {
      let fields = screen.secureFields
      try #require(fields.count == 3)
      try screen.replaceText(in: fields[0], with: current)
      try screen.replaceText(in: fields[1], with: new)
      try screen.replaceText(in: fields[2], with: confirmation)
    }

    @Test("Sign out asks first, and only yes signs out")
    func signOut() throws {
      var actions = ServerSettingsActions()
      let log = log
      actions.signOut = { log.record("out") }
      let screen = settingsForm(store: store) {
        AccountSettingsPane(
          account: ServerAccountState(userID: "ada@example.com", isAdmin: true), actions: actions)
      }
      defer { screen.close() }
      #expect(try screen.shows("Administrator"))
      #expect(screen.secureFields.isEmpty, "this account has no password to change")
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      try screen.clickControl(at: 0)
      #expect(SystemSideEffects.record.alertMessages == ["Sign out of this server?"])
      #expect(log.entries.isEmpty)
      SystemSideEffects.answer(alert: .alertFirstButtonReturn)
      try screen.clickControl(at: 0)
      #expect(log.entries == ["out"])
    }

    @Test(
      "a password account can change it; an unknown account still can; no sign-out action, no button"
    )
    func accountKinds() throws {
      let password = settingsForm(store: store) {
        AccountSettingsPane(
          account: ServerAccountState(userID: "ada", canChangePassword: true),
          actions: ServerSettingsActions())
      }
      defer { password.close() }
      #expect(password.secureFields.count == 3)
      #expect(try !password.shows("Administrator"))
      let unknown = settingsForm(store: store) {
        AccountSettingsPane(account: nil, actions: ServerSettingsActions())
      }
      defer { unknown.close() }
      #expect(unknown.secureFields.count == 3)
      #expect(try !unknown.shows("Signed in as"))
    }

    @Test("a change sends both passwords, clears the fields and confirms until the next typing")
    func changes() async throws {
      var actions = ServerSettingsActions()
      let log = log
      actions.changePassword = {
        log.record("change \($0) \($1)")
        return true
      }
      let screen = settingsForm(store: store) { ChangePasswordPane(actions: actions) }
      defer { screen.close() }
      try fill(screen, current: "old", new: "new", confirmation: "new")
      try screen.clickControl(at: 0)
      try await screen.letTasksRun()
      #expect(log.entries == ["change old new"])
      #expect(screen.secureFields.allSatisfy { $0.stringValue.isEmpty })
      #expect(try screen.shows("Password changed"))
      try screen.replaceText(in: screen.secureFields[0], with: "x")
      #expect(try !screen.shows("Password changed"))
    }

    @Test("passwords that differ say so and can't be sent")
    func mismatch() throws {
      var actions = ServerSettingsActions()
      let log = log
      actions.changePassword = { _, _ in
        log.record("sent")
        return true
      }
      let screen = settingsForm(store: store) { ChangePasswordPane(actions: actions) }
      defer { screen.close() }
      try fill(screen, current: "old", new: "new", confirmation: "other")
      #expect(try screen.shows("The new passwords don't match."))
      #expect(screen.controlFrames.isEmpty, "Change Password is disabled")
    }

    @Test("a refused change keeps what was typed and claims nothing")
    func refused() async throws {
      var actions = ServerSettingsActions()
      actions.changePassword = { _, _ in false }
      let screen = settingsForm(store: store) { ChangePasswordPane(actions: actions) }
      defer { screen.close() }
      try fill(screen, current: "old", new: "new", confirmation: "new")
      try screen.clickControl(at: 0)
      try await screen.letTasksRun()
      #expect(screen.secureFields[0].stringValue == "old")
      #expect(try !screen.shows("Password changed"))
    }

    @Test("a change in flight can't be sent again")
    func noDoubleSend() async throws {
      let gate = AsyncGate()
      var actions = ServerSettingsActions()
      let log = log
      actions.changePassword = { _, _ in
        log.record("sent")
        await gate.wait()
        return true
      }
      let screen = settingsForm(store: store) { ChangePasswordPane(actions: actions) }
      defer { screen.close() }
      try fill(screen, current: "old", new: "new", confirmation: "new")
      let button = try #require(screen.controlFrames.first)
      try screen.clickControl(at: 0)
      try await screen.letTasksRun()
      try screen.click(CGPoint(x: button.midX, y: button.midY))
      try await screen.letTasksRun()
      #expect(log.entries == ["sent"])
      gate.open()
      try await screen.letTasksRun()
    }
  }
#endif
