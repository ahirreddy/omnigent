#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Harness fix sheet, clicked", .serialized)
  @MainActor
  struct SettingsHarnessFixTests {
    private let log = ActionLog()

    private var actions: HarnessFixActions {
      let log = log
      return HarnessFixActions(
        confirmSwitch: { log.record("switch \($0 ?? "nil")") },
        checkAgain: { log.record("check") }, retry: { log.record("retry") },
        continueSetup: { log.record("continue") }, close: { log.record("close") })
    }

    private func screen(
      _ phase: HarnessFixSheetState.Phase, isChecking: Bool = false
    ) -> OffscreenWindow<some View> {
      let state = HarnessFixSheetState(
        title: "Switch Account", hostName: "Mac", phase: phase, isChecking: isChecking)
      let actions = actions
      return sheetScreen { HarnessFixSheet(state: state, actions: actions) }
    }

    /// Clicks every button of the sheet, form first and toolbar last.
    private func clickAll<Content>(_ screen: OffscreenWindow<Content>, count: Int) throws {
      let frames = screen.sheetButtons
      try #require(frames.count == count)
      for frame in frames { try screen.click(CGPoint(x: frame.midX, y: frame.midY)) }
    }

    @Test("switching names who's signed in, warns, and sends a trimmed email or none")
    func confirmSwitch() throws {
      let screen = screen(.confirmSwitch(account: "ada@example.com", asksForEmail: true))
      defer { screen.close() }
      #expect(try screen.shows("Mac is signed in as ada@example.com."))
      let field = try #require(screen.fields.first)
      try screen.replaceText(in: field, with: " bob@example.com ")
      try clickAll(screen, count: 2)
      #expect(log.entries == ["close", "switch bob@example.com"])
    }

    @Test("switching without an email sends none, and an unknown account still reads well")
    func confirmSwitchBlank() throws {
      let screen = screen(.confirmSwitch(account: nil, asksForEmail: false))
      defer { screen.close() }
      #expect(try screen.shows("Mac is signed in as the current account."))
      #expect(screen.fields.isEmpty)
      try clickAll(screen, count: 2)
      #expect(log.entries == ["close", "switch nil"])
    }

    @Test(
      "work in progress can only be canceled",
      arguments: [
        (HarnessFixSheetState.Phase.working("Signing out"), "Signing out"),
        (.waitingForOtherSignIn, "Another sign-in is already in progress on Mac."),
      ])
    func inProgress(phase: HarnessFixSheetState.Phase, text: String) throws {
      let screen = screen(phase)
      defer { screen.close() }
      #expect(try screen.shows(text))
      try clickAll(screen, count: 1)
      #expect(log.entries == ["close"])
    }

    @Test("a command to run can be copied, and Check Again says if it's still not done")
    func runCommand() throws {
      let screen = screen(.runCommand(command: "codex login", hint: "Hint", stillNotReady: true))
      defer { screen.close() }
      #expect(try screen.shows("Still not signed in on Mac."))
      #expect(try screen.shows("Hint"))
      // The command in the form, then Close and Check Again.
      try clickAll(screen, count: 3)
      #expect(log.entries == ["close", "check"])
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "codex login")
    }

    @Test("Check Again can't be pressed while a check runs")
    func checking() throws {
      let screen = screen(
        .runCommand(command: "c", hint: "h", stillNotReady: false), isChecking: true)
      defer { screen.close() }
      #expect(try !screen.shows("Still not signed in"))
      #expect(try screen.shows("Checking\u{2026}"))
      // The command and Close: Check Again is off.
      #expect(screen.sheetButtons.count == 2)
    }

    @Test("needing setup offers to continue it")
    func needsSetup() throws {
      let screen = screen(.needsSetup("Finish setup first"))
      defer { screen.close() }
      #expect(try screen.shows("Finish setup first"))
      try clickAll(screen, count: 2)
      #expect(log.entries == ["close", "continue"])
    }

    @Test("a failure says nothing changed, why, and how to do it by hand")
    func failed() throws {
      let screen = screen(.failed("The host refused"))
      defer { screen.close() }
      #expect(try screen.shows("Nothing changed on Mac."))
      #expect(try screen.shows("The host refused"))
      try clickAll(screen, count: 3)
      #expect(log.entries == ["close", "retry"])
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "omni setup")
    }

    @Test("finishing shows what happened and closes with Done")
    func done() throws {
      let screen = screen(.done("Signed in as bob"))
      defer { screen.close() }
      #expect(try screen.shows("Signed in as bob"))
      try clickAll(screen, count: 1)
      #expect(log.entries == ["close"])
    }

    @Test("a device code copies its code and link, and the link opens in the browser")
    func deviceCode() throws {
      let link = try #require(URL(string: "https://example.com/device"))
      let screen = screen(
        .deviceCode(link: link, code: "ABCD-1234", expiresAt: .now.addingTimeInterval(90)))
      defer { screen.close() }
      #expect(try screen.shows("ABCD-1234"))
      #expect(try screen.shows("Code expires in 1:"))
      // Open Sign-In Page, Copy Link, Copy Code, Cancel.
      try #require(screen.sheetButtons.count == 4)
      try screen.clickSheetButton(at: 0)
      #expect(SystemSideEffects.record.openedURLs == [link])
      try screen.clickSheetButton(at: 1)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == link.absoluteString)
      #expect(try screen.shows("Copied"))
      try screen.clickSheetButton(at: 2)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "ABCD-1234")
      try screen.clickSheetButton(at: 3)
      #expect(log.entries == ["close"])
    }

    @Test("a sign-in link the host garbled says so, rather than showing a dead code")
    func deviceCodeWithoutLink() throws {
      let screen = screen(.deviceCode(link: nil, code: "ABCD", expiresAt: .now))
      defer { screen.close() }
      #expect(try screen.shows("The host returned an invalid sign-in link."))
      #expect(try !screen.shows("ABCD"))
    }
  }

  @Suite("Harness setup sheet, clicked", .serialized)
  @MainActor
  struct SettingsHarnessSetupTests {
    private let log = ActionLog()

    private var actions: HarnessSetupActions {
      let log = log
      return HarnessSetupActions(
        install: { log.record("install") }, saveCredential: { log.record("save \($0)") },
        credentialFormOpened: { log.record("opened") }, close: { log.record("close") })
    }

    private func step(
      _ id: String, _ control: HarnessSetupStepState.Control, login: String? = nil,
      status: HarnessSetupStepState.Status = .todo
    ) -> HarnessSetupStepState {
      HarnessSetupStepState(
        id: id, title: "Step \(id)", detail: "Detail \(id)", status: status, control: control,
        loginCommand: login)
    }

    private func screen(_ state: HarnessSetupSheetState) -> OffscreenWindow<some View> {
      let actions = actions
      return sheetScreen { HarnessSetupSheet(state: state, actions: actions) }
    }

    private func credentialState(
      isSaving: Bool = false, adoptable: String? = "~/.codex/auth.json"
    ) -> HarnessSetupSheetState {
      HarnessSetupSheetState(
        name: "Codex", hostName: "Mac",
        steps: [step("key", .credential(enabled: true), login: "codex login")],
        isSavingCredential: isSaving, adoptableSource: adoptable)
    }

    /// Opens the credential form with the step's own button, which then reads Cancel.
    private func openForm<Content>(_ screen: OffscreenWindow<Content>) throws {
      try screen.clickSheetButton(at: 0)
      screen.settle(0.1)
    }

    @Test("Install installs, and says it's running while it does")
    func install() throws {
      let ready = screen(
        HarnessSetupSheetState(name: "Codex", hostName: "Mac", steps: [step("i", .install)]))
      defer { ready.close() }
      #expect(try ready.shows("Detail i"))
      try ready.clickSheetButton(at: 0)
      #expect(log.entries == ["install"])
    }

    @Test("an install in flight says so and can't be started twice")
    func installing() throws {
      let screen = screen(
        HarnessSetupSheetState(
          name: "Codex", hostName: "Mac", steps: [step("i", .install)], isInstalling: true))
      defer { screen.close() }
      #expect(try screen.shows("Installing on Mac."))
      #expect(try !screen.shows("Detail i"))
      #expect(screen.sheetButtons.count == 1, "only Close")
    }

    @Test("Close reads Done once everything is, and says it's ready")
    func close() throws {
      let unfinished = screen(HarnessSetupSheetState(name: "Codex", hostName: "Mac"))
      defer { unfinished.close() }
      #expect(try unfinished.shows("Close"))
      try unfinished.clickSheetButton(at: 0)
      #expect(log.entries == ["close"])
      let finished = screen(HarnessSetupSheetState(name: "Codex", hostName: "Mac", allDone: true))
      defer { finished.close() }
      #expect(try finished.shows("Done"))
      #expect(try finished.shows("Codex is ready on Mac."))
    }

    @Test("what it needs from the terminal, and any notice or error, show")
    func messages() throws {
      let omni = screen(
        HarnessSetupSheetState(
          name: "Codex", hostName: "Mac", needsOmniSetup: true, notice: "Saved",
          errorMessage: "Refused"))
      defer { omni.close() }
      #expect(try omni.shows("Codex needs a bit more setup on Mac."))
      #expect(try omni.shows("Saved"))
      #expect(try omni.shows("Refused"))
      let loading = screen(HarnessSetupSheetState(name: "Codex", hostName: "Mac", isLoading: true))
      defer { loading.close() }
      #expect(try !loading.shows("needs a bit more setup"))
    }

    @Test("a command step copies its command, every status drawn")
    func commandStep() throws {
      let screen = screen(
        HarnessSetupSheetState(
          name: "Codex", hostName: "Mac",
          steps: [
            step("a", .command("codex trust ."), status: .unknown),
            step("b", .none, status: .done),
          ]))
      defer { screen.close() }
      try screen.clickSheetButton(at: 0)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "codex trust .")
      #expect(try screen.shows("Step b"))
    }

    @Test("sign-in can't open before install")
    func credentialDisabled() throws {
      let screen = screen(
        HarnessSetupSheetState(
          name: "Codex", hostName: "Mac", steps: [step("k", .credential(enabled: false))]))
      defer { screen.close() }
      #expect(screen.sheetButtons.count == 1, "only Close")
    }

    @Test("Set Up Sign-In opens the form and tells the host; Cancel closes it")
    func credentialToggle() throws {
      let screen = screen(credentialState())
      defer { screen.close() }
      #expect(try !screen.shows("Use an API key"))
      try openForm(screen)
      #expect(log.entries == ["opened"])
      #expect(try screen.shows("Use an API key"))
      #expect(try screen.shows("~/.codex/auth.json"))
      #expect(try screen.shows("Cancel"))
      try openForm(screen)
      #expect(try !screen.shows("Use an API key"))
      #expect(log.entries == ["opened"])
    }

    @Test("opening the form needs nothing from a host that doesn't care")
    func formOpenedDefault() throws {
      let state = credentialState()
      let actions = HarnessSetupActions(install: {}, saveCredential: { _ in }, close: {})
      let screen = sheetScreen { HarnessSetupSheet(state: state, actions: actions) }
      defer { screen.close() }
      try openForm(screen)
      #expect(try screen.shows("Use an API key"))
    }

    @Test("a found credential can be adopted, and the login command copied")
    func adopt() throws {
      let screen = screen(credentialState())
      defer { screen.close() }
      try openForm(screen)
      // Cancel, Use It, the login command, Close.
      try screen.clickSheetButton(at: 1)
      #expect(log.entries.last == "save \(HarnessCredentialChoice.adopt)")
      try screen.clickSheetButton(at: 2)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "codex login")
    }

    @Test("an API key saves trimmed, from the button or Return, and spaces don't save")
    func apiKey() throws {
      let screen = screen(credentialState(adoptable: nil))
      defer { screen.close() }
      try openForm(screen)
      let key = try #require(screen.secureFields.first)
      try screen.replaceText(in: key, with: "   ")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(log.entries == ["opened"])
      try screen.replaceText(in: key, with: " sk-1 ")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(log.entries.last == "save \(HarnessCredentialChoice.apiKey("sk-1"))")
    }

    @Test("a gateway needs both its URL and key, and saves them trimmed")
    func gateway() throws {
      let screen = screen(credentialState(adoptable: nil))
      defer { screen.close() }
      try openForm(screen)
      let url = try #require(screen.fields.first)
      let key = try #require(screen.secureFields.last)
      try screen.replaceText(in: url, with: " https://proxy.test ")
      try screen.click(key)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(log.entries == ["opened"], "no key yet")
      try screen.replaceText(in: key, with: " gk ")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(
        log.entries.last
          == "save \(HarnessCredentialChoice.gateway(baseURL: "https://proxy.test", apiKey: "gk"))")
    }

    @Test("a credential being saved can't be saved again")
    func saving() throws {
      let screen = screen(credentialState(isSaving: true))
      defer { screen.close() }
      try openForm(screen)
      let key = try #require(screen.secureFields.first)
      try screen.replaceText(in: key, with: "sk")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(!log.entries.contains { $0.hasPrefix("save") })
    }
  }
#endif
