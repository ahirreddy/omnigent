import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("CLI tool calls: arguments, what a call did, and an edit's lines")
struct CLIToolCallTests {
  private func entry(
    _ id: String = "c", tool: String, arguments: String, output: String? = nil,
    isFailure: Bool = false
  ) -> ToolEntry {
    let call = Row(
      id: id, role: .tool,
      activity: Activity(kind: .toolCall, title: tool, summary: arguments, status: "completed"),
      callId: id)
    let result = output.map {
      Row(
        id: "\(id)-result", role: .tool,
        activity: Activity(
          kind: .toolResult, title: "Result",
          details: [DetailSection(id: "output", title: "Output", text: $0)], isFailure: isFailure),
        callId: id)
    }
    return ToolEntry(call: call, result: result)
  }

  // MARK: Arguments

  @Test("the core's display text reads as fields; later lines continue the value before them")
  func displayTextFields() {
    let arguments = CLIToolArguments("command: echo a\ndescription: Says a\ntwice\nworkdir: /repo")
    #expect(
      arguments.fields == [
        CLIToolArguments.Field(key: "command", value: "echo a"),
        CLIToolArguments.Field(key: "description", value: "Says a\ntwice"),
        CLIToolArguments.Field(key: "workdir", value: "/repo"),
      ])
    #expect(arguments.bare.isEmpty)
    #expect(arguments.value(["cmd", "command"]) == "echo a")
    #expect(arguments.value(["missing"]) == nil)
    // A key that does not sort after the last one is part of that value.
    let folded = CLIToolArguments("command: cat <<EOF\nalpha: 1\nEOF")
    #expect(folded.fields == [.init(key: "command", value: "cat <<EOF\nalpha: 1\nEOF")])
    let bare = CLIToolArguments("  ls -la\n")
    #expect(bare.fields.isEmpty)
    #expect(bare.bare == "ls -la")
  }

  @Test("JSON arguments read the same way as the display text made from them")
  func jsonArguments() {
    let json = #"{"b": ["x", "y"], "a": {"n": 2, "none": null}, "c": "text"}"#
    let arguments = CLIToolArguments(json)
    #expect(arguments.value(["a"]) == "n: 2\nnone: ")
    #expect(arguments.value(["b"]) == "x\ny")
    #expect(arguments.value(["c"]) == "text")
  }

  @Test("a listed object starts where the sorted keys start over")
  func listedObjects() {
    let arguments = CLIToolArguments("note: plan: later\nplan: a: 1\nb: 2\na: 3\nmore\nb: 4")
    #expect(arguments.items("plan") == [["a": "1", "b": "2"], ["a": "3\nmore", "b": "4"]])
    #expect(arguments.items("todos").isEmpty)
    #expect(CLIToolArguments("plan: a: 1").items("plan") == [["a": "1"]])
  }

  // MARK: Calls

  @Test("a call is named by its tool and arguments")
  func calls() {
    func call(_ tool: String, _ arguments: String) -> CLIToolCall {
      CLIToolCall(tool: tool, arguments: arguments)
    }
    #expect(call("shell", "command: /bin/bash -lc 'git status'") == .command("git status"))
    #expect(call("shell", "command: bash\n-lc\nls\nworkdir: /x") == .command("ls"))
    #expect(call("exec", "cmd: make all") == .command("make all"))
    #expect(call("omnigent__sys_os_shell", "ls") == .command("ls"))
    #expect(call("Bash", "") == .command("Bash"))
    #expect(call("Read", "file_path: a/b.swift\nlimit: 3") == .read("a/b.swift"))
    #expect(call("Read", "a/b.swift\nmore") == .read("a/b.swift"))
    #expect(call("Read", "") == .read("Read"))
    #expect(call("Glob", "path: src\npattern: *.swift") == .list("*.swift"))
    #expect(call("ls", "") == .list("."))
    #expect(call("Grep", "pattern: x") == .search(query: "x", path: nil))
    #expect(call("grep", "needle") == .search(query: "needle", path: nil))
    #expect(call("Edit", "file_path: a.swift") == .edit("a.swift"))
    #expect(call("", "") == .other(name: "tool", arguments: ""))
    #expect(call("github__search", "q: x") == .other(name: "github.search", arguments: "q: x"))
    let long = String(repeating: "a", count: 200)
    #expect(
      call("custom", long)
        == .other(
          name: "custom",
          arguments: String(repeating: "a", count: CLIToolCall.argumentCharacters) + "\u{2026}"))
  }

  @Test("a plan's steps carry their status; an entry with no text is left out")
  func planSteps() {
    let call = CLIToolCall(
      tool: "update_plan",
      arguments:
        "plan: status: done\nstep: A\nstatus: active\nstep: B\nstatus: odd\ntitle: C\nid: 9")
    #expect(
      call
        == .plan(
          note: nil,
          steps: [
            CLIPlanStep(text: "A", status: .completed), CLIPlanStep(text: "B", status: .inProgress),
            CLIPlanStep(text: "C", status: .pending),
          ]))
  }

  @Test("only calls that look around are explored, and only edits and unknown tools report changes")
  func kinds() {
    let calls: [CLIToolCall] = [
      .read("a/b.swift"), .list("src"), .search(query: "q", path: "src"), .command("ls"),
      .plan(note: nil, steps: []), .edit(nil), .other(name: "x", arguments: ""),
    ]
    #expect(
      calls.map { $0.explored?.title } == ["Read", "List", "Search", nil, nil, nil, nil])
    #expect(calls.map { $0.explored?.target } == ["b.swift", "src", "q", nil, nil, nil, nil])
    #expect(calls.map(\.reportsChanges) == [false, false, false, false, false, true, true])
  }

  @Test("a step reads its diff from the arguments, or from an edit's or unknown tool's output")
  func steps() {
    let diff = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b"
    #expect(CLIToolStep(entry(tool: "Edit", arguments: diff)).diff?.added == 1)
    #expect(CLIToolStep(entry(tool: "turn_diff", arguments: "", output: diff)).diff?.removed == 1)
    // A command that prints a diff ran a command; it did not make that change.
    let shown = CLIToolStep(entry(tool: "shell", arguments: "command: git diff", output: diff))
    #expect(shown.diff == nil)
    #expect(shown.input == "git diff")
    #expect(shown.output == diff)
    let silent = CLIToolStep(entry(tool: "Read", arguments: "path: a", output: "\n"))
    #expect(silent.output == nil)
    #expect(silent.input == "path: a")
    let orphan = CLIToolStep(ToolEntry(call: nil, result: Row(id: "r", role: .tool, text: "hi")))
    #expect(orphan.output == "hi")
    #expect(orphan.input.isEmpty)
  }

  @Test("explored lines join reads that worked; a search keeps its scope")
  func exploredLines() {
    let steps = [
      entry("a", tool: "Read", arguments: "path: x/a"),
      entry("b", tool: "Read", arguments: "path: x/b"),
      entry("c", tool: "Grep", arguments: "path: src\npattern: q"),
      entry("d", tool: "Read", arguments: "path: x/d", output: "no", isFailure: true),
      entry("e", tool: "Read", arguments: "path: x/e"),
    ].map(CLIToolStep.init)
    let lines = CLIExploredLine.lines(for: steps)
    #expect(lines.map(\.id) == ["a", "c", "d", "e"])
    #expect(lines.map(\.title) == ["Read", "Search", "Read", "Read"])
    #expect(lines.map(\.targets) == [["a", "b"], ["q"], ["d"], ["e"]])
    #expect(lines.map(\.scope) == [nil, "src", nil, nil])
    let empty = CLIExploredLine(steps: [])
    #expect(empty.id.isEmpty)
    #expect(empty.title.isEmpty)
    #expect(CLIToolCell.cells(for: []).isEmpty)
    #expect(CLIToolCell.explored([]).id == "explored:")
  }
}
