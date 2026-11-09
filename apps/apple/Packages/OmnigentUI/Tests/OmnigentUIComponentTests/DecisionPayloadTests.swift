#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// What a card says will actually happen, before its actions.
  @Suite("Decision card: payloads", .serialized)
  @MainActor
  struct DecisionPayloadTests {
    private let log = DecisionResponseLog()

    private func open(_ card: DecisionCard) -> OffscreenWindow<DecisionCardScreen> {
      let screen = OffscreenWindow(
        DecisionCardScreen(card: card, model: DecisionCardModel(), log: log))
      screen.settle()
      return screen
    }

    @Test("A command shows its directory and reason, and its copy button copies it")
    func command() throws {
      SystemSideEffects.reset()
      let card = DecisionCard.sample(
        detail: "cargo test",
        permissions: PermissionOptions(
          command: CommandApproval(command: "cargo test", cwd: "/src", reason: "To check it")))
      let screen = open(card)
      defer { screen.close() }
      #expect(try screen.shows("Command approval"))
      #expect(try screen.shows("$ cargo test"))
      #expect(try screen.shows("/src"))
      #expect(try screen.shows("To check it"))
      // The detail repeating the command isn't shown twice.
      #expect(try screen.shownText().filter { $0.contains("cargo test") }.count == 1)
      try screen.tapButton(0)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "cargo test")
    }

    @Test("A command's message shows above it")
    func commandLede() throws {
      let card = DecisionCard.sample(
        detail: "Run **the tests**\n\ncargo test",
        permissions: PermissionOptions(command: CommandApproval(command: "cargo test")))
      let screen = open(card)
      defer { screen.close() }
      #expect(try screen.shows("Run the tests"))
      #expect(try !screen.shows("**"))
    }

    @Test("Files read name first, with what happens and the counts left out at zero")
    func files() throws {
      let card = DecisionCard.sample(
        title: "Approval requested", detail: "Edit",
        permissions: PermissionOptions(files: [
          DecisionFileChange(path: "/src/new.swift", added: 11, removed: 0, kind: .create),
          DecisionFileChange(path: "/src/old.swift", added: 0, removed: 7, kind: .delete),
          DecisionFileChange(path: "bare.swift", kind: .write),
          DecisionFileChange(path: "/edit.swift", added: 2, removed: 3, kind: .modify),
          DecisionFileChange(path: "unknown.swift"),
        ]))
      let screen = open(card)
      defer { screen.close() }
      let shown = try screen.shownText()
      #expect(shown.contains("new.swift"))
      #expect(shown.contains("/src"))
      #expect(shown.contains("new file"))
      #expect(shown.contains("+11"))
      #expect(!shown.contains("\u{2212}0"))
      #expect(shown.contains("deleted"))
      #expect(shown.contains("\u{2212}7"))
      #expect(!shown.contains("+0"))
      #expect(shown.contains("rewritten"))
      #expect(shown.contains("bare.swift"))
      #expect(shown.contains("/"))
      #expect(shown.contains("+2"))
      #expect(shown.contains("\u{2212}3"))
    }

    @Test("Antigravity's action and pattern show, and persistence is offered for that pattern")
    func antigravity() throws {
      let agy = AntigravityPermission(
        actionDescription: "Run a build", alwaysAllowPattern: "make")
      let card = DecisionCard.sample(
        detail: "Run a build", permissions: PermissionOptions(antigravity: agy))
      let screen = open(card)
      defer { screen.close() }
      #expect(try screen.shows("Run a build"))
      #expect(try screen.shownText().filter { $0.contains("Run a build") }.count == 1)
      #expect(try screen.shows("Always-allow pattern"))
      #expect(try screen.shows("make"))
      let menu = try screen.menu(at: 0)
      #expect(
        menuTitles(menu) == [
          "Allow commands starting with make for this session",
          "Always allow commands starting with make",
        ])
    }

    @Test("Antigravity's message shows above an action that differs from it")
    func antigravityLede() throws {
      let card = DecisionCard.sample(
        detail: "It wants to build",
        permissions: PermissionOptions(
          antigravity: AntigravityPermission(actionDescription: "Make")))
      let screen = open(card)
      defer { screen.close() }
      #expect(try screen.shows("It wants to build"))
      #expect(try screen.shows("Make"))
      #expect(try !screen.shows("Always-allow pattern"))
    }

    @Test("Directories offered for the session are listed, and their count names the scope")
    func directories() throws {
      let card = DecisionCard.sample(
        detail: "Reach further",
        permissions: PermissionOptions(permissionDirectories: ["/one", "/two"]))
      let screen = open(card)
      defer { screen.close() }
      #expect(try screen.shows("Directories offered for this session"))
      #expect(try screen.shows("/one"))
      #expect(try screen.shows("/two"))
      #expect(
        menuTitles(try screen.menu(at: 0)) == ["Approve and allow 2 directories for this session"])
    }

    @Test("A named request keeps its name; the policy says who asks; a subagent is marked")
    func headers() throws {
      let card = DecisionCard.sample(
        title: "Apply the design?", detail: "A detail", policyName: "Team policy",
        targetSessionId: "child")
      let screen = open(card)
      defer { screen.close() }
      #expect(try screen.shows("Apply the design?"))
      #expect(try screen.shows("Team policy"))
      #expect(try screen.shows("From a subagent"))
    }

    @Test("A plain approval's other paragraphs are its preview, in code")
    func previewFromDetail() throws {
      let card = DecisionCard.sample(detail: "Use a tool\n\n{\"a\": \"b\\tc\"}\n\nmore")
      let screen = open(card)
      defer { screen.close() }
      #expect(try screen.shows("Use a tool"))
      #expect(try screen.shows("more"))
      #expect(try screen.shows("b\tc"))
    }

    @Test("A message and input show apart; no input means no preview")
    func messageAndInput() throws {
      let both = open(.sample(detail: "joined", message: "The message", toolInput: "Tool(1)"))
      defer { both.close() }
      #expect(try both.shows("The message"))
      #expect(try both.shows("Tool(1)"))
      #expect(try !both.shows("joined"))

      let alone = open(.sample(detail: "one paragraph\n\nsecond", message: "The message"))
      defer { alone.close() }
      #expect(try alone.shows("The message"))
      #expect(try !alone.shows("second"))
    }

    @Test("A long input folds with Show all, naming what's hidden, and then unfolds")
    func folding() throws {
      let input = (1...14).map { "line \($0)" }.joined(separator: "\n")
      let screen = open(.sample(message: "Long", toolInput: input))
      defer { screen.close() }
      #expect(try screen.shows("Show all \u{00B7} 2 more lines"))
      #expect(try !screen.shows("line 14"))
      // Show all comes before Approve, the first of the card's own actions.
      try screen.tapButton(0)
      #expect(try screen.shows("line 14"))
      #expect(try !screen.shows("Show all"))
    }

    @Test("One hidden line says line, not lines")
    func foldingOne() throws {
      let input = (1...13).map { "line \($0)" }.joined(separator: "\n")
      let screen = open(.sample(message: "Long", toolInput: input))
      defer { screen.close() }
      #expect(try screen.shows("Show all \u{00B7} 1 more line"))
    }

    @Test("An edit's input reads as a diff")
    func diffPreview() throws {
      let input = #"Edit({"file_path": "/a.swift", "old_string": "one", "new_string": "two"})"#
      let screen = open(.sample(message: "Edit", toolInput: input))
      defer { screen.close() }
      #expect(try screen.shows("a.swift"))
      #expect(try screen.shows("one"))
      #expect(try screen.shows("two"))
      #expect(try !screen.shows("old_string"))
    }

    @Test("Text that isn't valid Markdown shows as written")
    func markdownFallback() throws {
      let screen = OffscreenWindow(InlineMarkdownText("a **bold** `code`"))
      defer { screen.close() }
      screen.settle()
      #expect(try screen.shows("a bold code"))
    }

    // MARK: Previews, without a window

    @Test("A preview's diff comes from any harness's keys, a patch, or none at all")
    func previewDiffs() throws {
      let claude = try #require(
        ToolInputPreview.diff(
          in: #"Edit({"file_path":"/a","old_string":"x\ny","new_string":"x\nz"})"#))
      #expect(claude.added == 1)
      #expect(claude.removed == 1)
      #expect(
        ToolInputPreview.diff(in: #"{"oldText":"a","newText":"b"}"#) != nil)
      #expect(ToolInputPreview.diff(in: #"{"oldString":"a","newString":"a"}"#) == nil)
      #expect(ToolInputPreview.diff(in: #"{"command":"ls"}"#) == nil)
      #expect(ToolInputPreview.diff(in: #"[{"oldText":"a","newText":"b"}]"#) != nil)
      #expect(ToolInputPreview.diff(in: "not json at all") == nil)
      #expect(ToolInputPreview.diff(in: #"Tool({"broken": )"#) == nil)
      let patch = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"
      #expect(ToolInputPreview.diff(in: patch) != nil)
      let inString = #"{"patch": "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n", "path": "x"}"#
      #expect(ToolInputPreview.diff(in: inString)?.files.count == 1)
      let bareHunk = #"{"path": "y.swift", "diff": "@@ -1 +1 @@\n-a\n+b\n"}"#
      #expect(ToolInputPreview.diff(in: bareHunk)?.files.count == 1)
    }

    @Test("Replacing lines keeps the two nearest unchanged ones each side")
    func pairLines() {
      #expect(
        ToolInputPreview.pairLines(old: "1\n2\n3\nold\n4\n5\n6", new: "1\n2\n3\nnew\n4\n5\n6") == [
          " 2", " 3", "-old", "+new", " 4", " 5",
        ])
      #expect(ToolInputPreview.pairLines(old: "", new: "a") == ["+a"])
      #expect(ToolInputPreview.pairLines(old: "a", new: "") == ["-a"])
    }

    @Test("A preview's JSON escapes turn back into characters, outside its strings too")
    func unescaping() {
      #expect(ToolInputPreview.unescaped(#"{"a":"b\nc\td\re"}"#) == "{\"a\":\"b\nc\tde\"}")
      #expect(
        ToolInputPreview.unescaped(#""\"quoted\" \\ A""#)
          == #""\"quoted\" \\ A""#.replacingOccurrences(of: #"\""#, with: "\"")
          .replacingOccurrences(of: #"\\"#, with: "\\"))
      #expect(ToolInputPreview.unescaped(#""\uZZZZ""#) == #""\uZZZZ""#)
      #expect(ToolInputPreview.unescaped(#""\u00"#) == #""\u00"#)
      #expect(ToolInputPreview.unescaped("\"ends in \\") == "\"ends in \\")
      #expect(ToolInputPreview.unescaped(#"plain \n"#) == #"plain \n"#)
    }

    @Test("A code layout wraps on a phone and when the review says so")
    func codeLayout() {
      #expect(DecisionCodeLayout.automatic.wraps(.compact))
      #expect(!DecisionCodeLayout.automatic.wraps(.regular))
      #expect(DecisionCodeLayout.fullScreen(wraps: true).wraps(.regular))
      #expect(!DecisionCodeLayout.fullScreen(wraps: false).wraps(.compact))
      #expect(DecisionCodeLayout.fullScreen(wraps: false).isFullScreen)
      #expect(!DecisionCodeLayout.automatic.isFullScreen)
    }

    @Test("What counts as a large request")
    func payloadSize() {
      func large(_ card: DecisionCard) -> Bool { DecisionPayloadSize.isLarge(card) }
      #expect(large(.sample(permissions: PermissionOptions(plan: "A plan"))))
      let file = DecisionFileChange(path: "a")
      #expect(large(.sample(permissions: PermissionOptions(files: [file, file, file, file]))))
      #expect(!large(.sample(permissions: PermissionOptions(files: [file]))))
      #expect(large(.command("a\nb")))
      #expect(large(.command(String(repeating: "a", count: 121))))
      #expect(!large(.command()))
      #expect(!large(.sample(detail: "One line")))
      #expect(!large(.sample(kind: .choice(answerKey: "a", options: []))))
      #expect(large(.sample(toolInput: String(repeating: "a", count: 401))))
      #expect(large(.sample(detail: "First\n\n1\n2\n3\n4\n5\n6\n7")))
      #expect(!large(.sample(detail: "First\n\nsmall")))
      let bigDiff = (1...8).map { "+line \($0)" }.joined(separator: "\n")
      #expect(large(.sample(toolInput: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n" + bigDiff)))
      #expect(!large(.sample(toolInput: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b")))
    }
  }
#endif
