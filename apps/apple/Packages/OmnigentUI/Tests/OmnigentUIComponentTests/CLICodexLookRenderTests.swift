#if os(macOS)
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Renders the CLI blocks a terminal agent draws most (markdown, commands, exploring, edits,
  /// notices) as PNGs when `OMNIGENT_UI_RENDER_DIR` is set, to compare with the Codex CLI.
  @Suite("CLI style: the Codex look", .serialized)
  @MainActor
  struct CLICodexLookRenderTests {
    private typealias Fixture = TranscriptFixture

    static let markdown = """
      # Heading one

      ## Heading two

      ### Heading three

      #### Heading four

      A paragraph with **bold**, *italic*, ~~struck~~ and `inline code`, a \
      [link](https://example.com) and https://example.org.
      A second source line of the same paragraph.

      - First item
      - Second item
        - Nested item
        - Another nested item
      - [ ] Open task
      - [x] Done task

      1. Ordered one
      2. Ordered two is long enough that it wraps onto a second line in a narrow window, so \
      the spacing between the items shows
         1. Nested ordered

      > A quote that
      > spans two lines.
      >
      > > A nested quote

      ```swift
      let answer = 42 // the answer
      ```

      ```
      a plain fence
      ```

      | Name | Value |
      | --- | ---: |
      | alpha | 1 |
      | beta | 22 |

      ---

      <div>raw html</div>
      """

    static let patch = """
      *** Begin Patch
      *** Update File: Sources/App/Greeter.swift
      @@
       struct Greeter {
      -  let greeting = "Hello"
      +  let greeting = "Hello, world"
      +  let punctuation = "!"
       }
      *** End Patch
      """

    private static func call(
      _ id: String, _ tool: String, _ arguments: String, status: String? = "completed"
    ) -> Row {
      Fixture.toolCall(
        id, title: tool, summary: arguments, status: status,
        details: [DetailSection(id: "arguments", title: "Arguments", text: arguments, isCode: true)]
      )
    }

    /// A login-shell command's arguments as the core records them: one field a line.
    private static func shell(_ script: String) -> String {
      "command: /usr/bin/zsh -lc '\(script)'\nworkdir: /repo"
    }

    static let script = "python3 - <<PY\nimport json\nprint(json.dumps({}))\nprint(1)\nPY"

    static let plan = """
      explanation: Fix the greeting, then prove it
      plan: status: completed
      step: Read the greeter
      status: in_progress
      step: Change the greeting
      status: pending
      step: Run the tests
      """

    static func toolRows() -> [Row] {
      let listing = (1...8).map { "file\($0).swift" }.joined(separator: "\n")
      return [
        Fixture.user("u1", "run the checks, look around and fix the greeting\nthen tell me"),
        call("c0", "update_plan", plan),
        Fixture.toolResult("r0", callID: "c0", output: "Plan updated"),
        call("c1", "shell", shell("git status --short")),
        Fixture.toolResult("r1", callID: "c1", output: " M Sources/App/Greeter.swift"),
        call("c2", "shell", shell("ls Sources/App")),
        Fixture.toolResult("r2", callID: "c2", output: listing),
        call("c3", "shell", shell("swift test --filter Greeter")),
        Fixture.toolResult(
          "r3", callID: "c3", output: "error: 1 test failed\nGreeterTests.greets", isFailure: true),
        call("c4", "shell", shell(script)),
        Fixture.toolResult("r4", callID: "c4", output: ""),
        call("c5", "Read", "file_path: Sources/App/Greeter.swift"),
        Fixture.toolResult("r5", callID: "c5", output: "struct Greeter {}"),
        call("c6", "Read", "file_path: Tests/AppTests/GreeterTests.swift"),
        Fixture.toolResult("r6", callID: "c6", output: "import Testing"),
        call("c7", "Grep", "path: Sources\npattern: greeting"),
        Fixture.toolResult("r7", callID: "c7", output: "Sources/App/Greeter.swift:2"),
        call("c8", "apply_patch", "input: " + patch),
        Fixture.toolResult("r8", callID: "c8", output: "Done"),
        call("c9", "mcp__docs__find_page", "limit: 3\nquery: greeting style"),
        Fixture.toolResult("r9", callID: "c9", output: "Found the style guide"),
        call("c10", "shell", shell("swift build"), status: "in_progress"),
      ]
    }

    static func noticeRows() -> [Row] {
      [
        Fixture.answer("a1", "The greeting is fixed."),
        Fixture.activityRow(.reasoning, id: "t1", summary: "Weighed the two greetings"),
        Fixture.activityRow(
          .terminal, id: "s1", title: "Terminal command", summary: "make test",
          details: [DetailSection(id: "input", title: "Command", text: "make test")]),
        Fixture.activityRow(
          .terminal, id: "s2", title: "Terminal output", summary: "ok 12 tests",
          details: [DetailSection(id: "stdout", title: "Output", text: "ok 12 tests\nok 3 suites")]
        ),
        Fixture.activityRow(
          .error, id: "e1", summary: "The model stopped answering", isFailure: true),
        Fixture.activityRow(.compaction, id: "k1", title: "Compacted the conversation"),
      ]
    }

    private func gallery(_ rows: [Row], rendering: OutputRendering) -> some View {
      VStack(alignment: .leading, spacing: CLIMetrics.blockGap) {
        ForEach(TranscriptLayout.items(for: rows)) { CLIItemView(item: $0, decorations: [:]) }
        CLIWorkingLine(isBlocked: false, startedAt: nil)
      }
      .padding(.vertical, CLIMetrics.blockGap)
      .background { CLICanvas() }
      .cliPalette()
      .transcriptAppearance(TranscriptAppearance(style: .cli, outputRendering: rendering))
      .omnigentTheme(.nord)
    }

    private func render(_ rows: [Row], rendering: OutputRendering, name: String) throws {
      let rendered = try RenderSupport.render(
        gallery(rows, rendering: rendering), width: 760, scheme: .dark, layout: .regular)
      #expect(RenderSupport.inkCoverage(rendered) > 0.01, "\(name) rendered blank")
      try RenderSupport.write(rendered, name: "codex-look-\(name)")
    }

    @Test("markdown draws in the styled and plain renderings")
    func markdown() throws {
      let rows = [
        Fixture.user("u1", "show me every kind of output"), Fixture.answer("a1", Self.markdown),
      ]
      try render(rows, rendering: .styled, name: "markdown-styled")
      try render(rows, rendering: .plain, name: "markdown-plain")
    }

    @Test("commands, exploring, edits and other tools draw as cells")
    func tools() throws {
      try render(Self.toolRows(), rendering: .styled, name: "tools")
    }

    @Test("reasoning, a shell command, an error and a notice draw as lines")
    func notices() throws {
      try render(Self.noticeRows(), rendering: .styled, name: "notices")
    }
  }
#endif
