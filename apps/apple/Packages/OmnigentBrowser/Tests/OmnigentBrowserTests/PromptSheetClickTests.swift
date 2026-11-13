#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentBrowser

  /// A tab's page in a SwiftUI window, so its prompts open as sheets on a window that takes events.
  private struct TabPage: NSViewRepresentable {
    let page: NSView

    func makeNSView(context: Context) -> NSView { page }
    func updateNSView(_ view: NSView, context: Context) {}
  }

  /// A presenter whose tab is in an offscreen window, with alerts opening as real sheets.
  @MainActor
  private struct SheetPage {
    let fixture: PresenterFixture
    let screen: OffscreenWindow<TabPage>

    init(
      profile: BrowserProfile = .server("sheets"),
      credentials: any BrowserCredentialStore = InMemoryBrowserCredentialStore()
    ) throws {
      fixture = try PresenterFixture(profile: profile, credentials: credentials)
      screen = OffscreenWindow(TabPage(page: fixture.tab.platformView), width: 600, height: 400)
      SystemSideEffects.showAlertSheets()
    }

    var presenter: BrowserPromptPresenter { fixture.presenter }
    var isSheetUp: Bool { screen.window.attachedSheet != nil }

    /// The titles of the sheet's buttons, checkboxes included.
    var buttonTitles: [String] {
      screen.allViews.compactMap { ($0 as? NSButton)?.title }.filter { !$0.isEmpty }
    }

    func button(_ title: String) throws -> NSButton {
      let found = screen.allViews.compactMap { $0 as? NSButton }.first { $0.title == title }
      guard let found else { throw OffscreenWindowError.notFound("the button \(title)") }
      return found
    }

    /// Clicks the sheet's button of this title.
    func press(_ title: String) throws {
      try screen.click(try button(title))
    }

    /// The sheet's editable fields, top to bottom.
    var fields: [NSTextField] {
      screen.allViews.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }

    /// Clicks into a field and types over whatever it holds.
    func type(_ text: String, into field: NSTextField) throws {
      try screen.click(field)
      (screen.activeWindow.firstResponder as? NSText)?.selectAll(nil)
      try screen.type(text)
    }

    func request(_ prompt: BrowserPrompt) {
      presenter.tab(fixture.tab, didRequest: prompt)
      screen.settle()
    }

    /// Closes the window, and has alerts answer at once again for the suites that follow.
    func close() {
      screen.close()
      SystemSideEffects.reset()
    }
  }

  @MainActor
  @Suite("Prompt sheets, pressed", .serialized)
  struct PromptSheetClickTests {
    private func ask(_ page: SheetPage, _ kind: BrowserDialogKind, answers: Answers<String?>) {
      let prompt = BrowserDialogPrompt(
        kind: kind, origin: nil, message: "Hello", defaultText: "typed"
      ) { accepted, text in answers.values.append(accepted ? text ?? "accepted" : nil) }
      page.request(.dialog(prompt))
    }

    @Test("an alert waits for its one button, OK, and then answers the page")
    func alertOK() throws {
      let page = try SheetPage()
      defer { page.close() }
      let answers = Answers<String?>()
      ask(page, .alert, answers: answers)
      #expect(page.isSheetUp)
      #expect(answers.values.isEmpty, "nothing is answered until a button is pressed")
      #expect(page.buttonTitles.contains("OK"))
      #expect(!page.buttonTitles.contains("Cancel"))
      try page.press("OK")
      #expect(answers.values == ["accepted"])
      #expect(!page.isSheetUp)
      #expect(page.presenter.presentedPrompt == nil)
    }

    @Test("a confirm's Cancel refuses and its OK accepts; Escape and Return do the same")
    func confirmButtonsAndKeys() throws {
      let page = try SheetPage()
      defer { page.close() }
      let answers = Answers<String?>()
      ask(page, .confirm, answers: answers)
      try page.press("Cancel")
      #expect(answers.values == [nil])
      ask(page, .confirm, answers: answers)
      try page.press("OK")
      #expect(answers.values == [nil, "accepted"])
      ask(page, .confirm, answers: answers)
      try page.screen.press(keyCode: 53, characters: "\u{1B}")
      #expect(answers.values == [nil, "accepted", nil])
      ask(page, .confirm, answers: answers)
      try page.screen.press(keyCode: 36, characters: "\r")
      #expect(answers.values == [nil, "accepted", nil, "accepted"])
      #expect(!page.isSheetUp)
    }

    @Test("a prompt's OK answers what was typed over its default; Cancel answers nothing")
    func promptText() throws {
      let page = try SheetPage()
      defer { page.close() }
      let answers = Answers<String?>()
      ask(page, .prompt, answers: answers)
      let field = try #require(page.fields.first)
      #expect(field.stringValue == "typed")
      try page.type("new words", into: field)
      try page.press("OK")
      #expect(answers.values == ["new words"])
      ask(page, .prompt, answers: answers)
      try page.type("thrown away", into: try #require(page.fields.first))
      try page.press("Cancel")
      #expect(answers.values == ["new words", nil])
    }

    @Test("leaving a page with unsaved changes offers Leave and Cancel")
    func beforeUnload() throws {
      let page = try SheetPage()
      defer { page.close() }
      let answers = Answers<String?>()
      ask(page, .beforeUnload, answers: answers)
      #expect(page.buttonTitles.contains("Leave"))
      #expect(!page.buttonTitles.contains("OK"))
      try page.press("Cancel")
      #expect(answers.values == [nil])
      ask(page, .beforeUnload, answers: answers)
      try page.press("Leave")
      #expect(answers.values == [nil, "accepted"])
    }

    private func permission(_ page: SheetPage, answers: Answers<BrowserPermissionAnswer>)
      -> BrowserPermissionPrompt
    {
      let prompt = BrowserPermissionPrompt(
        origin: "https://a.example", permissions: [.camera, .microphone]
      ) { answers.values.append($0) }
      page.request(.permission(prompt))
      return prompt
    }

    private func decision(_ page: SheetPage) -> BrowserPermissionDecision? {
      page.presenter.permissionStore.decision(
        for: .camera, origin: "https://a.example", profile: page.fixture.tab.profile)
    }

    @Test("Allow, with Remember ticked as it opens, allows and is not asked again")
    func allowRemembered() throws {
      let page = try SheetPage()
      defer { page.close() }
      let answers = Answers<BrowserPermissionAnswer>()
      _ = permission(page, answers: answers)
      #expect(try page.button("Remember for this site").state == .on)
      #expect(answers.values.isEmpty)
      try page.press("Allow")
      #expect(answers.values == [.allow])
      #expect(decision(page) == .allow)
      _ = permission(page, answers: answers)
      #expect(!page.isSheetUp, "the remembered answer needs no sheet")
      #expect(answers.values == [.allow, .allow])
    }

    @Test("with Remember unticked, Allow allows once and the site is asked again")
    func allowOnce() throws {
      let page = try SheetPage()
      defer { page.close() }
      let answers = Answers<BrowserPermissionAnswer>()
      _ = permission(page, answers: answers)
      try page.press("Remember for this site")
      #expect(try page.button("Remember for this site").state == .off)
      try page.press("Allow")
      #expect(answers.values == [.allow])
      #expect(decision(page) == nil, "nothing was remembered")
      _ = permission(page, answers: answers)
      #expect(page.isSheetUp, "asked again")
      try page.press("Don't Allow")
      #expect(answers.values == [.allow, .deny])
      #expect(decision(page) == .deny)
    }

    @Test("a permission the page withdraws closes its sheet and decides nothing")
    func permissionWithdrawn() throws {
      let page = try SheetPage()
      defer { page.close() }
      let answers = Answers<BrowserPermissionAnswer>()
      let prompt = permission(page, answers: answers)
      #expect(page.isSheetUp)
      page.presenter.tab(page.fixture.tab, didCancel: .permission(prompt))
      page.screen.settle()
      #expect(!page.isSheetUp)
      #expect(answers.values == [.dismiss])
      #expect(decision(page) == nil)
    }

    private func authenticate(_ page: SheetPage) -> Answers<BrowserCredential?> {
      let answers = Answers<BrowserCredential?>()
      let prompt = BrowserAuthPrompt(space: PresenterFixture.space) { answers.values.append($0) }
      page.request(.authentication(prompt))
      return answers
    }

    @Test("Sign In sends the typed name and password, and Remember in Keychain stores them")
    func signInRemembered() throws {
      let store = InMemoryBrowserCredentialStore()
      let page = try SheetPage(credentials: store)
      defer { page.close() }
      let answers = authenticate(page)
      let fields = page.fields
      try #require(fields.count == 2)
      #expect(fields[1] is NSSecureTextField)
      try page.type("ada", into: fields[0])
      try page.type("lovelace", into: fields[1])
      #expect(try page.button("Remember in Keychain").state == .off)
      try page.press("Remember in Keychain")
      try page.press("Sign In")
      let typed = BrowserCredential(username: "ada", password: "lovelace")
      #expect(answers.values == [typed])
      #expect(store.credential(for: PresenterFixture.space) == typed)
    }

    @Test("Sign In without Remember stores nothing, and Cancel sends no credential")
    func signInOnceAndCancel() throws {
      let store = InMemoryBrowserCredentialStore()
      let page = try SheetPage(credentials: store)
      defer { page.close() }
      let answers = authenticate(page)
      try page.type("ada", into: try #require(page.fields.first))
      try page.press("Sign In")
      #expect(answers.values == [BrowserCredential(username: "ada", password: "")])
      #expect(store.credential(for: PresenterFixture.space) == nil)

      let cancelled = authenticate(page)
      try page.type("ada", into: try #require(page.fields.first))
      try page.press("Cancel")
      #expect(cancelled.values.count == 1 && cancelled.values[0] == nil)
      #expect(store.credential(for: PresenterFixture.space) == nil)
    }

    @Test("a private profile's sign-in sheet has no Remember in Keychain to tick")
    func privateSignIn() throws {
      let page = try SheetPage(profile: .ephemeral("private"))
      defer { page.close() }
      let answers = authenticate(page)
      #expect(try page.button("Remember in Keychain").isHidden)
      try page.press("Cancel")
      #expect(answers.values.count == 1 && answers.values[0] == nil)
    }
  }
#endif
