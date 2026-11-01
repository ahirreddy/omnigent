import Testing

@testable import OmnigentAuthUI

/// A validator whose normalizer answers like the core: rejects `rejected`, rewrites `rewrites`.
private func validator(
  rejecting rejected: Set<String> = [], rewriting rewrites: [String: String] = [:]
) -> ServerURLValidator {
  ServerURLValidator { raw in
    if rejected.contains(raw) {
      return .failure(ServerURLRejection(message: "rejected \(raw)"))
    }
    return .success(rewrites[raw] ?? raw)
  }
}

struct ServerURLValidationTests {
  @Test func emptyAndBlankFieldsAreEmpty() {
    let subject = validator()
    #expect(subject.check("") == .empty)
    #expect(subject.check("  \n\t ") == .empty)
    #expect(!subject.check("").canConnect)
  }

  @Test func trimsBeforeNormalizing() {
    let subject = validator(rewriting: ["host.example": "https://host.example"])
    #expect(subject.check("  host.example \n") == .valid(normalized: "https://host.example"))
  }

  @Test func rejectionCarriesTheCoreMessage() {
    let subject = validator(rejecting: ["http://x.example"])
    #expect(subject.check("http://x.example") == .invalid(message: "rejected http://x.example"))
    #expect(!subject.check("http://x.example").canConnect)
  }

  @Test func invalidHintWaitsUntilRevealed() throws {
    let subject = validator(rejecting: ["bad"])
    #expect(subject.hint(for: "bad", revealed: false) == nil)
    let hint = try #require(subject.hint(for: "bad", revealed: true))
    #expect(hint.text == "rejected bad")
    #expect(hint.isError)
  }

  @Test func validHintShowsOnlyWhenNormalizationChangesTheURL() throws {
    let subject = validator(rewriting: ["host.example": "https://host.example"])
    let hint = try #require(subject.hint(for: "host.example", revealed: false))
    #expect(hint.text == "Connects to https://host.example")
    #expect(!hint.isError)
    #expect(subject.hint(for: "https://same.example", revealed: true) == nil)
    #expect(subject.hint(for: "", revealed: true) == nil)
  }

  @Test(arguments: [
    ("omnigent.example.com", "https://omnigent.example.com"),
    ("https://omnigent.example.com/", "https://omnigent.example.com"),
    ("127.0.0.1:6767", "http://127.0.0.1:6767"),
    ("http://localhost:6767", "http://localhost:6767"),
  ])
  func previewValidatorAcceptsReleaseURLs(input: String, normalized: String) {
    #expect(ServerURLValidator.preview.check(input) == .valid(normalized: normalized))
  }

  @Test(arguments: ["http://omnigent.example.com", "ftp://omnigent.example.com", "has space"])
  func previewValidatorRejectsOthers(input: String) {
    #expect(!ServerURLValidator.preview.check(input).canConnect)
  }
}

struct CredentialsValidationTests {
  @Test func submitNeedsUsernameAndPassword() {
    #expect(CredentialsInput.canSubmit(username: "ada", password: "pw", isSubmitting: false))
    #expect(!CredentialsInput.canSubmit(username: "  ", password: "pw", isSubmitting: false))
    #expect(!CredentialsInput.canSubmit(username: "ada", password: "", isSubmitting: false))
    #expect(!CredentialsInput.canSubmit(username: "ada", password: "pw", isSubmitting: true))
  }

  @Test func passwordIsNotTrimmed() {
    #expect(CredentialsInput.canSubmit(username: "ada", password: " ", isSubmitting: false))
    let credentials = AccountCredentials(username: "  ada \n", password: " p w ")
    #expect(credentials.username == "ada")
    #expect(credentials.password == " p w ")
  }

  @Test func returnMovesThroughTheForm() {
    typealias Step = CredentialsInput.Step
    func step(_ fromPassword: Bool, _ user: String, _ password: String, busy: Bool = false) -> Step
    {
      CredentialsInput.returnStep(
        fromPassword: fromPassword, username: user, password: password, isSubmitting: busy)
    }
    #expect(step(false, "ada", "") == .focusPassword)
    #expect(step(false, "", "") == .none)
    #expect(step(false, "ada", "pw") == .submit)
    #expect(step(true, "ada", "pw") == .submit)
    #expect(step(true, "", "pw") == .focusUsername)
    #expect(step(true, "ada", "") == .none)
    #expect(step(true, "ada", "pw", busy: true) == .none)
  }

  @Test func credentialsNeverPrintThePassword() {
    let secret = "correct horse battery staple"
    let credentials = AccountCredentials(username: "ada", password: secret)
    var dumped = ""
    dump(credentials, to: &dumped)
    for text in [
      String(describing: credentials), String(reflecting: credentials), "\(credentials)", dumped,
    ] {
      #expect(!text.contains(secret), "leaked in: \(text)")
      #expect(text.contains("ada"))
    }
  }
}

struct ServerTextTests {
  @Test func keepsMarkupLiteral() {
    let text = "Sign-ins from <b>gmail.com</b> are not allowed. [Request](https://evil.example)"
    #expect(ServerText.escaped(text) == text)
  }

  @Test func escapesBidiOverridesAndControls() {
    #expect(ServerText.escaped("abc\u{202E}gpj.exe") == "abc\\u{202E}gpj.exe")
    #expect(ServerText.escaped("a\u{1B}[31mred") == "a\\u{1B}[31mred")
    #expect(ServerText.escaped("a\rb") == "a\\u{D}b")
    #expect(ServerText.escaped("x\u{2066}y\u{2069}") == "x\\u{2066}y\\u{2069}")
  }

  @Test func keepsNewlinesTabsAndUnicodeText() {
    #expect(ServerText.escaped("line 1\nline\t2") == "line 1\nline\t2")
    #expect(
      ServerText.escaped("Zugriff verweigert \u{2014} caf\u{E9}")
        == "Zugriff verweigert \u{2014} caf\u{E9}")
  }

  @Test func capsLength() {
    let long = String(repeating: "a", count: 600)
    let escaped = ServerText.escaped(long)
    #expect(escaped.count == ServerText.defaultLimit + 1)
    #expect(escaped.hasSuffix("\u{2026}"))
    #expect(ServerText.escaped("abc", limit: 3) == "abc")
  }
}
