#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentAuthUI

  /// The username and password form, with every state it can show.
  @MainActor
  @Suite("Password sign-in form", .serialized)
  struct SignInFormTests {
    private func hosted(
      server: ServerIdentity = AuthSamples.accountsServer, banner: AuthBanner? = nil,
      isSubmitting: Bool = false, spy: AuthSpy
    ) -> OffscreenWindow<PasswordSignInView> {
      OffscreenWindow(
        PasswordSignInView(
          server: server, banner: banner, isSubmitting: isSubmitting, actions: spy.actions()),
        width: 560, height: 640)
    }

    @Test(
      "Sign In waits for both fields, then submits the trimmed username and clears the password")
    func submits() throws {
      let spy = AuthSpy()
      let screen = hosted(spy: spy)
      defer { screen.close() }
      let before = screen.controlFrames.count
      try screen.fill(0, " ada ")
      #expect(screen.controlFrames.count == before, "no password yet: Sign In stays off")
      try screen.fill(1, "hunter2")
      #expect(screen.controlFrames.count == before + 1, "Sign In came on")
      try screen.clickFromEnd()
      #expect(spy.credentials.map(\.username) == ["ada"])
      #expect(spy.credentials.map(\.password) == ["hunter2"])
      #expect(screen.fields[1].stringValue.isEmpty, "the password doesn't stay on screen")
    }

    // `@FocusState` doesn't move AppKit's focus offscreen, so Return moving to the password is for
    // a real flow; `CredentialsInput.returnStep` has unit tests of which step comes next.
    @Test("Return in the password signs in; Return in the username alone doesn't")
    func returnKey() throws {
      let spy = AuthSpy()
      let screen = hosted(spy: spy)
      defer { screen.close() }
      try screen.fill(0, "ada")
      try screen.pressReturn()
      #expect(spy.credentials.isEmpty, "no password yet")
      try screen.fill(1, "hunter2")
      try screen.pressReturn()
      #expect(spy.credentials.map(\.username) == ["ada"])
    }

    @Test("Return with nothing typed doesn't submit")
    func emptyReturn() throws {
      let spy = AuthSpy()
      let screen = hosted(spy: spy)
      defer { screen.close() }
      try screen.click(screen.fields[1])
      try screen.pressReturn()
      #expect(spy.credentials.isEmpty)
    }

    @Test("submitting shows progress, locks the fields and can't submit again")
    func submitting() throws {
      let spy = AuthSpy()
      let screen = hosted(isSubmitting: true, spy: spy)
      defer { screen.close() }
      #expect(try screen.shows("Signing In\u{2026}"))
      #expect(screen.fields.allSatisfy { !$0.isEnabled })
      #expect(spy.credentials.isEmpty)
    }

    @Test("Use Another Server leaves the form")
    func cancel() throws {
      let spy = AuthSpy()
      let screen = hosted(spy: spy)
      defer { screen.close() }
      try screen.clickFromEnd()
      #expect(spy.log == ["cancel"], "\(screen.controlFrames)")
    }

    @Test("Have an invite opens the register form")
    func invite() throws {
      let spy = AuthSpy()
      let screen = hosted(spy: spy)
      defer { screen.close() }
      #expect(try screen.shows("Have an invite?"))
      try screen.clickFromEnd(1)
      #expect(spy.log == ["form register"], "\(screen.controlFrames)")
    }

    @Test("a server with no admin offers to create one and to open setup")
    func needsSetup() throws {
      SystemSideEffects.reset()
      var server = AuthSamples.accountsServer
      server.needsSetup = true
      let spy = AuthSpy()
      let screen = hosted(server: server, spy: spy)
      defer { screen.close() }
      #expect(try screen.shows("This server has no administrator yet."))
      #expect(try screen.shows("Open Setup in Browser"))
      let controls = screen.controlFrames
      try #require(controls.count >= 2)
      try screen.click(CGPoint(x: controls[0].midX, y: controls[0].midY))
      #expect(spy.log == ["form createAdmin"], "\(controls)")
      try screen.click(CGPoint(x: controls[1].midX, y: controls[1].midY))
      #expect(SystemSideEffects.record.openedURLs.count == 1)
    }

    private static let wrongPassword = SignInError(
      category: .auth, failure: .signInRequired, message: "Wrong username or password.")

    @Test(
      "the banner titles a refused or required sign-in and leaves others to the error",
      arguments: [
        (SignInFailure.signInRequired, true),
        (.refused(reason: "Not allowed here"), true),
        (.expired, false), (.endedByServer, false), (.transport, false), (.failed, false),
      ] as [(SignInFailure, Bool)])
    func bannerTitles(failure: SignInFailure, titled: Bool) throws {
      let error = SignInError(category: .auth, failure: failure, message: "Details here.")
      let spy = AuthSpy()
      let screen = hosted(banner: .error(error), spy: spy)
      defer { screen.close() }
      #expect(try screen.shows("Couldn\u{2019}t sign in") == titled)
    }

    @Test("an error with no kind shows its message")
    func plainError() throws {
      let spy = AuthSpy()
      let screen = hosted(banner: .error(Self.wrongPassword), spy: spy)
      defer { screen.close() }
      #expect(try screen.shows("Couldn\u{2019}t sign in"))
    }

    @Test("a transport failure offers Retry, which connects again")
    func retry() throws {
      let error = SignInError(category: .transport, failure: .transport, message: "Timed out.")
      let spy = AuthSpy()
      let screen = hosted(banner: .error(error), spy: spy)
      defer { screen.close() }
      #expect(try screen.shows("Retry"))
      try screen.clickControl(at: 0)
      #expect(spy.log == ["retry"], "\(screen.controlFrames)")
    }

    @Test("the description never shows a password")
    func redacted() {
      let credentials = AccountCredentials(username: " ada ", password: "hunter2")
      #expect(credentials.username == "ada")
      #expect(!credentials.description.contains("hunter2"))
      #expect(!credentials.debugDescription.contains("hunter2"))
      #expect(!String(reflecting: credentials).contains("hunter2"))
      let mirrored = Mirror(reflecting: credentials).children.map { "\($0.value)" }
      #expect(!mirrored.contains("hunter2"))
    }
  }

  /// Creating the first admin or an invited account.
  @MainActor
  @Suite("Create account form", .serialized)
  struct CreateAccountFormTests {
    private func hosted(
      form: AccountForm, banner: AuthBanner? = nil, isSubmitting: Bool = false,
      inviteLink: String? = nil, spy: AuthSpy
    ) -> OffscreenWindow<CreateAccountView> {
      OffscreenWindow(
        CreateAccountView(
          server: AuthSamples.accountsServer, form: form, banner: banner,
          isSubmitting: isSubmitting, inviteLink: inviteLink, actions: spy.actions()),
        width: 560, height: 720)
    }

    private static let invite = "https://omnigent.example.com/register?invite=tok-1"

    @Test("the first admin's form creates the admin with the lowercased username")
    func createsAdmin() throws {
      let spy = AuthSpy()
      let screen = hosted(form: .createAdmin, spy: spy)
      defer { screen.close() }
      #expect(try screen.shows("Create the admin account"))
      #expect(screen.fields.count == 3)
      try screen.fill(0, "Ada")
      #expect(screen.fields[0].stringValue == "ada", "lowercased as typed")
      try screen.fill(1, "correct-horse-1")
      try screen.fill(2, "correct-horse-1")
      try screen.clickFromEnd()
      let request = try #require(spy.creations.first)
      #expect(request.kind == .firstAdmin)
      #expect(request.credentials.username == "ada")
      #expect(request.credentials.password == "correct-horse-1")
      #expect(screen.fields[1].stringValue.isEmpty, "passwords are cleared once sent")
      #expect(screen.fields[2].stringValue.isEmpty)
    }

    @Test("passwords that differ say so and block creating")
    func mismatch() throws {
      let spy = AuthSpy()
      let screen = hosted(form: .createAdmin, spy: spy)
      defer { screen.close() }
      try screen.fill(0, "ada")
      try screen.fill(1, "correct-horse-1")
      try screen.fill(2, "different-horse")
      let problem = AccountFormInput.problem(
        password: "correct-horse-1", confirmation: "different-horse")
      #expect(try screen.shows(try #require(problem)))
      try screen.pressReturn()
      #expect(spy.creations.isEmpty)
    }

    @Test("an invite form needs a real invite and sends its token")
    func invited() throws {
      let spy = AuthSpy()
      let screen = hosted(form: .register, spy: spy)
      defer { screen.close() }
      #expect(try screen.shows("Join your team"))
      #expect(screen.fields.count == 4)
      try screen.fill(0, "https://omnigent.example.com/register")
      #expect(try screen.shows("That isn\u{2019}t an invite link."))
      try screen.fill(1, "ada")
      try screen.fill(2, "correct-horse-1")
      try screen.fill(3, "correct-horse-1")
      try screen.pressReturn()
      #expect(spy.creations.isEmpty, "no token yet")
      screen.fields[0].stringValue = ""
      try screen.click(screen.fields[0])
      try screen.press(keyCode: 0, characters: "a", modifiers: .command)
      try screen.type(Self.invite)
      #expect(try !screen.shows("That isn\u{2019}t an invite link."))
    }

    @Test("a link that opened the app is prefilled; Return in the last field sends its token")
    func prefilled() throws {
      let spy = AuthSpy()
      let screen = hosted(form: .register, inviteLink: Self.invite, spy: spy)
      defer { screen.close() }
      #expect(screen.fields[0].stringValue == Self.invite)
      try screen.click(screen.fields[0])
      try screen.pressReturn()
      try screen.fill(1, "ada")
      try screen.pressReturn()
      try screen.fill(2, "correct-horse-1")
      try screen.pressReturn()
      #expect(spy.creations.isEmpty, "not until the confirmation")
      try screen.fill(3, "correct-horse-1")
      try screen.pressReturn()
      #expect(spy.creations.first?.kind == .invited(token: "tok-1"))
    }

    @Test("Sign In Instead goes back; a failure is titled; creating shows progress")
    func otherStates() throws {
      let spy = AuthSpy()
      let error = SignInError(category: .auth, message: "That username is taken.")
      let screen = hosted(form: .createAdmin, banner: .error(error), spy: spy)
      defer { screen.close() }
      #expect(try screen.shows("Couldn\u{2019}t create the account"))
      try screen.clickFromEnd()
      #expect(spy.log == ["form signIn"], "\(screen.controlFrames)")
      let busy = hosted(form: .createAdmin, isSubmitting: true, spy: spy)
      defer { busy.close() }
      #expect(try busy.shows("Creating\u{2026}"))
      #expect(busy.fields.allSatisfy { !$0.isEnabled })
    }
  }
#endif
