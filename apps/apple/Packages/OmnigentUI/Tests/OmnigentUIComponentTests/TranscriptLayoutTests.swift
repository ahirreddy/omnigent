import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Transcript layout")
struct TranscriptLayoutTests {
  private func call(_ id: String, _ callID: String, kind: ActivityKind = .toolCall) -> Row {
    Row(id: id, role: .tool, activity: Activity(kind: kind, title: id), callId: callID)
  }

  @Test("groups consecutive tool calls and pairs results by call id")
  func groupsTools() throws {
    let rows = [
      Row(id: "u1", role: .user, text: "Hi"),
      call("c1", "a"),
      call("c2", "b"),
      call("r1", "a", kind: .toolResult),
      Row(id: "a1", role: .assistant, text: "Done"),
    ]
    let items = TranscriptLayout.items(for: rows)
    #expect(items.count == 3)
    guard case .tools(_, let entries) = items[1] else {
      Issue.record("expected a tool group")
      return
    }
    #expect(entries.map(\.id) == ["c1", "c2"])
    #expect(entries[0].result?.id == "r1")
    #expect(entries[1].result == nil)
    #expect(entries[1].isRunning)
    #expect(!entries[0].isRunning)
  }

  @Test("a non-tool activity splits tool runs; an orphan result is its own entry")
  func splitsRuns() {
    let rows = [
      call("c1", "a"),
      Row(id: "think", role: .tool, activity: Activity(kind: .reasoning, title: "Reasoning")),
      call("r9", "zz", kind: .toolResult),
    ]
    let items = TranscriptLayout.items(for: rows)
    #expect(items.map(\.id) == ["tools:c1", "think", "tools:r9"])
  }

  @Test("activity-only rows leave the transcript")
  func dropsLifecycle() {
    let rows = [
      Row(
        id: "res", role: .tool, activity: Activity(kind: .resource, title: "Terminal"),
        isActivityOnly: true),
      Row(id: "u", role: .user, text: "Hi"),
    ]
    #expect(TranscriptLayout.items(for: rows).map(\.id) == ["u"])
  }

  @Test("every sample row kind lands in the transcript or the inspector")
  func coversSampleKinds() {
    let kinds = Set(PreviewData.rows.compactMap(\.activity?.kind))
    #expect(kinds == Set(ActivityKind.allCases))
    let shown = Set(TranscriptLayout.items(for: PreviewData.rows).flatMap(\.rowIDs))
    let hidden = Set(PreviewData.rows.filter(\.isActivityOnly).map(\.id))
    #expect(shown.union(hidden) == Set(PreviewData.rows.map(\.id)))
  }

  @Test("a settled turn folds its tool work and keeps the final answer visible")
  func workedFold() {
    let rows = [
      Row(id: "u", role: .user, text: "Hi"),
      Row(
        id: "c1", role: .tool, activity: Activity(kind: .toolCall, title: "Bash"), callId: "a",
        responseId: "r"),
      Row(
        id: "o1", role: .tool, activity: Activity(kind: .toolResult, title: "out"), callId: "a",
        responseId: "r"),
      Row(
        id: "think", role: .tool, activity: Activity(kind: .reasoning, title: "Reasoning"),
        responseId: "r"),
      Row(
        id: "err", role: .tool, activity: Activity(kind: .error, title: "Error", isFailure: true),
        responseId: "r"),
      Row(id: "a1", role: .assistant, text: "Done", responseId: "r"),
    ]
    let segments = TurnLayout.segments(TranscriptLayout.items(for: rows), isRunning: false)
    #expect(segments.map(\.id) == ["u", "worked:tools:c1", "err", "a1"])
    guard case .worked(_, let response, let items, let live) = segments[1] else {
      Issue.record("expected a Worked fold")
      return
    }
    #expect(response == "r")
    #expect(items.map(\.id) == ["tools:c1", "think"])
    #expect(!live)
  }

  @Test("the live turn stays open and keeps the streaming answer outside")
  func liveTurn() {
    let rows = [
      Row(id: "u", role: .user, text: "Hi"),
      Row(id: "c1", role: .tool, activity: Activity(kind: .toolCall, title: "Read"), callId: "a"),
      Row(id: "live", role: .assistant, text: "So far", isStreaming: true),
    ]
    let segments = TurnLayout.segments(TranscriptLayout.items(for: rows), isRunning: true)
    guard case .worked(_, _, _, let live) = segments[1] else {
      Issue.record("expected a Worked fold")
      return
    }
    #expect(live)
    #expect(segments.last?.id == "live")
  }

  @Test("durations and tool summaries read like the web")
  func webStrings() {
    #expect(TurnLayout.duration(8) == "8s")
    #expect(TurnLayout.duration(106) == "1m 46s")
    #expect(TurnLayout.duration(60) == "1m")
    #expect(TurnLayout.duration(3_720) == "1h 2m")
    #expect(ToolRunSummary.text(for: ["Bash", "shell", "shell"]) == "Ran 3 shell commands")
    #expect(
      ToolRunSummary.text(for: ["Bash", "Read", "Read"]) == "Ran 1 shell command, read 2 files")
    #expect(ToolRunSummary.text(for: ["mcp__linear__create"]) == "Called 1 tool")
    #expect(ToolRunSummary.text(for: ["Read", "custom"]) == "Read 1 file, called 1 other tool")
  }

  @Test("3,000 rows lay out quickly with unique, stable ids")
  func largeTranscript() {
    let state = PreviewData.largeConversation(count: 3_000)
    let clock = ContinuousClock()
    var items: [TranscriptItem] = []
    let elapsed = clock.measure { items = TranscriptLayout.items(for: state.rows) }
    #expect(Set(items.map(\.id)).count == items.count)
    #expect(items.map(\.id) == TranscriptLayout.items(for: state.rows).map(\.id))
    #expect(elapsed < .milliseconds(250))
  }
}

@Suite("Diff detection")
struct DiffSummaryTests {
  @Test("counts a Codex patch and names its file")
  func codexPatch() throws {
    let diff = try #require(DiffSummary.parse(PreviewData.patch))
    #expect(diff.added == 4)
    #expect(diff.removed == 3)
    #expect(diff.files == ["client-core/crates/omnigent-core/src/auth/refresh.rs"])
  }

  @Test("finds a patch inside JSON tool arguments")
  func jsonArguments() throws {
    let json = #"{"input": "*** Begin Patch\n*** Add File: a.txt\n+hello\n*** End Patch"}"#
    let diff = try #require(DiffSummary.find(in: json))
    #expect(diff.added == 1)
    #expect(diff.files == ["a.txt"])
  }

  @Test("plain output is not a diff")
  func plainText() {
    #expect(DiffSummary.find(in: "test result: ok. 3 passed") == nil)
    #expect(DiffSummary.find(in: "{\"path\": \"a.rs\"}") == nil)
  }
}

@Suite("Markdown")
struct MarkdownTests {
  @Test("parses headings, lists, tables, code, quotes and rules")
  func blocks() {
    let blocks = MarkdownParser.parse(PreviewData.assistantMarkdown)
    #expect(blocks.contains { if case .heading(2, _) = $0 { true } else { false } })
    #expect(blocks.contains { if case .code("rust", _) = $0 { true } else { false } })
    #expect(blocks.contains { if case .quote = $0 { true } else { false } })
    let table = blocks.compactMap { if case .table(let table) = $0 { table } else { nil } }.first
    #expect(table?.header.count == 3)
    #expect(table?.rows.count == 3)
    #expect(table?.alignments == [.leading, .center, .trailing])
    let tasks = blocks.compactMap { block -> [MarkdownTask] in
      if case .list(false, _, let items) = block { return items.map(\.task) }
      return []
    }
    #expect(tasks.contains([.checked, .checked, .unchecked]))
  }

  @Test("keeps only http, https and mailto links")
  func linkSafety() {
    let blocks = MarkdownParser.parse(
      "[a](https://example.com) [b](javascript:alert(1)) [c](file:///etc/passwd) [d](mailto:x@y.z)")
    guard case .paragraph(let text)? = blocks.first else {
      Issue.record("expected a paragraph")
      return
    }
    let links = text.runs.compactMap(\.link).map(\.absoluteString)
    #expect(links == ["https://example.com", "mailto:x@y.z"])
  }

  @Test("images render as alt text and are never fetched")
  func images() {
    guard case .paragraph(let text)? = MarkdownParser.parse("![chart](https://x.test/c.png)").first
    else {
      Issue.record("expected a paragraph")
      return
    }
    #expect(String(text.characters) == "[Image: chart]")
  }

  @Test("an unterminated fence while streaming is still a code block")
  func streamingFence() {
    let blocks = MarkdownParser.parse("Here:\n\n```swift\nlet x = 1")
    #expect(blocks.count == 2)
    #expect(blocks.last == .code(language: "swift", code: "let x = 1"))
  }
}

@Suite("Decision forms")
struct DecisionFormTests {
  let fields = PreviewData.formFields

  @Test("required answers and unparseable numbers are reported before the core validator")
  func localProblems() {
    var draft = FormDraft()
    #expect(draft.localProblem(for: fields) == "Enter PR title.")
    draft.text["title"] = "Coalesce refreshes"
    #expect(draft.localProblem(for: fields) == "Choose Yes or No for Open as draft.")
    draft.booleans["draft"] = true
    draft.custom["base"] = "hotfix"
    draft.text["reviewers"] = "two"
    #expect(draft.localProblem(for: fields) == "Reviewers must be a whole number.")
    draft.text["reviewers"] = "2"
    #expect(draft.localProblem(for: fields) == nil)
  }

  @Test("builds typed values; a custom answer wins over a selection")
  func values() {
    var draft = FormDraft()
    draft.text["title"] = "T"
    draft.text["reviewers"] = "2"
    draft.booleans["draft"] = false
    draft.selected["base"] = ["main"]
    draft.custom["base"] = "hotfix"
    draft.selected["labels"] = ["tests", "auth"]
    let values = draft.values(for: fields)
    #expect(values["title"] == .text(value: "T"))
    #expect(values["reviewers"] == .integer(value: 2))
    #expect(values["draft"] == .bool(value: false))
    #expect(values["base"] == .text(value: "hotfix"))
    #expect(values["labels"] == .textList(values: ["auth", "tests"]))
    #expect(values["token"] == nil)
  }

  @Test("standing-permission responses are flagged for confirmation")
  func standingPermissions() {
    #expect(DecisionResponse.approvePersist(mode: .always).changesStandingPermissions)
    #expect(DecisionResponse.approveCommandPolicy(policy: ["cargo"]).changesStandingPermissions)
    #expect(!DecisionResponse.approve.changesStandingPermissions)
    #expect(!DecisionResponse.declineWithFeedback(feedback: "no").changesStandingPermissions)
  }

  @Test("Antigravity's always-allow pattern offers both persistence modes")
  func persistOffers() {
    let permissions = PreviewData.antigravity.permissions
    #expect(permissions.offersPersist(.session))
    #expect(permissions.offersPersist(.always))
    #expect(!PermissionOptions().offersPersist(.session))
  }

  @Test("phases: an answered card without a phase reads as answered")
  func phases() {
    var state = PreviewData.conversation
    state.decisions = [PreviewData.answered, PreviewData.choice]
    #expect(state.phase(of: PreviewData.answered) == .answered(summary: "Response sent"))
    #expect(state.phase(of: PreviewData.choice) == .pending)
    #expect(state.pendingDecisions.map(\.id) == [PreviewData.choice.id])
  }
}

@Suite("Session list and sections")
struct SessionListTests {
  @Test("default grouping is Pinned, Projects, Shared, Sessions")
  func defaultSections() {
    let sections = SidebarSections.sections(PreviewData.sidebar)
    #expect(sections.map(\.title) == ["Pinned", "Projects", "Shared", "Sessions"])
    let sessions = sections.last?.sessions.map(\.id) ?? []
    #expect(!sessions.contains("sess_a2"))  // in a project
    #expect(!sessions.contains("sess_a4"))  // shared
    #expect(!sessions.contains("sess_p1"))  // pinned
    #expect(sections.last?.showsDisplayMenu == true)
  }

  @Test("relative times use the web's short form")
  func relativeTimes() {
    let now = PreviewData.now
    #expect(RelativeTime.short(now, now: now) == "now")
    #expect(RelativeTime.short(now.addingTimeInterval(-300), now: now) == "5m")
    #expect(RelativeTime.short(now.addingTimeInterval(-3 * 3_600), now: now) == "3h")
    #expect(RelativeTime.short(now.addingTimeInterval(-2 * 86_400), now: now) == "2d")
    #expect(RelativeTime.short(now.addingTimeInterval(-8 * 86_400), now: now) == "1w")
    #expect(RelativeTime.short(now.addingTimeInterval(-60 * 86_400), now: now) == "2mo")
    #expect(RelativeTime.short(now.addingTimeInterval(-400 * 86_400), now: now) == "1y")
  }

  @Test("completions offer slash commands and @ mentions")
  func completions() {
    let slash = ComposerCompletions(draft: "/re", commands: PreviewData.slashCommands, mentions: [])
    #expect(slash.items.map(\.title) == ["/review"])
    #expect(slash.applying(slash.items[0]) == "/review ")
    let mention = ComposerCompletions(
      draft: "look at @tests", commands: [], mentions: PreviewData.mentionPaths)
    #expect(mention.items.count == 1)
    #expect(mention.applying(mention.items[0]).hasPrefix("look at @client-core"))
    #expect(
      ComposerCompletions(draft: "hello", commands: PreviewData.slashCommands, mentions: []).items
        .isEmpty)
  }

  @Test("command completions rank prefixes first, honor $ skills and stop at an exact name")
  func commandCompletions() {
    let commands = [
      SlashCommand(name: "compact"), SlashCommand(name: "help"),
      SlashCommand(name: "review", prefix: "$", isSkill: true),
      SlashCommand(name: "code-review", prefix: "$", isSkill: true),
    ]
    let slash = ComposerCompletions(draft: "/rev", commands: commands, mentions: [])
    #expect(slash.items.map(\.title) == ["$review", "$code-review"])
    #expect(slash.applying(slash.items[0]) == "$review ")
    let dollar = ComposerCompletions(draft: "$", commands: commands, mentions: [])
    #expect(dollar.items.map(\.title) == ["$review", "$code-review"])
    #expect(ComposerCompletions(draft: "/help", commands: commands, mentions: []).items.isEmpty)
    #expect(ComposerCompletions(draft: "/help me", commands: commands, mentions: []).items.isEmpty)
  }

  @Test("Shift-Tab cycles approval modes and wraps")
  func approvalModes() {
    var modes = PreviewData.claudeModes
    #expect(modes.next?.label == "Auto-edit")
    modes.selectedID = "auto"
    #expect(modes.next?.label == "Ask first")
  }

  @Test("reads todos, usage, changed files and viewers from the core's sections")
  func sections() throws {
    let state = PreviewData.conversation
    let todos = SectionReading.todos(try #require(state.section("todos")))
    #expect(todos.map(\.state) == [.completed, .completed, .inProgress, .pending])
    let usage = SectionReading.usage(try #require(state.section("usage")))
    #expect(usage.contextTokens == 84_200)
    #expect(usage.fraction.map { abs($0 - 84_200.0 / 128_000.0) < 0.0001 } == true)
    let files = SectionReading.changedFiles(try #require(state.section("files-default")))
    #expect(files.map(\.letter) == ["M", "M", "A"])
    let viewers = SectionReading.viewers(try #require(state.section("presence")))
    #expect(viewers.map(\.initials) == ["AR", "A", "SL"])
    #expect(viewers.last?.isIdle == true)
  }

  @Test("harness aliases resolve to one appearance")
  func harnessAppearance() {
    #expect(HarnessAppearance(harness: "codex-native-ui").label == "Codex")
    #expect(HarnessAppearance(harness: "claude-native").label == "Claude Code")
    #expect(HarnessAppearance(harness: "claude-sdk").label == "Claude SDK")
    #expect(HarnessAppearance(harness: "my-custom").identifier == "fallback")
    #expect(HarnessAppearance(harness: "my-custom").label == "My Custom")
  }

  @Test("a built-in native agent reads as its harness, any other as its own name")
  func agentNames() {
    #expect(HarnessAppearance.agentName("codex-native-ui", harness: "codex-native") == "Codex")
    #expect(HarnessAppearance.agentName("claude-native-ui", harness: nil) == "Claude Code")
    #expect(HarnessAppearance.agentName("reviewer", harness: "codex-native") == "reviewer")
  }
}
