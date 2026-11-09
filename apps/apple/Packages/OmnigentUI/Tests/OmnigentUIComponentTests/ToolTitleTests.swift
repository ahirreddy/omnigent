import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Tool titles match the web's")
struct ToolTitleTests {
  private struct ToolCall {
    let tool: String
    let arguments: [String: Any]
    let expected: String

    init(_ tool: String, _ arguments: [String: Any], _ expected: String) {
      self.tool = tool
      self.arguments = arguments
      self.expected = expected
    }
  }

  private func json(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object)
    return try #require(String(data: data, encoding: .utf8))
  }

  @Test("raw harness names read as actions")
  func harnessTools() throws {
    let cases: [ToolCall] = [
      ToolCall("turn_diff", [:], "Turn diff"),
      ToolCall("shell", ["command": "/bin/bash -lc 'cat notes.txt'"], "$ cat notes.txt"),
      ToolCall("shell", ["command": "ls -la"], "$ ls -la"),
      ToolCall("sys_os_shell", ["command": "ls"], "$ ls"),
      ToolCall("mcp__omnigent__sys_os_shell", ["command": "ls"], "$ ls"),
      ToolCall("bash", ["command": "ls"], "$ ls"),
      ToolCall("Bash", ["command": "ls", "description": "List files"], "List files"),
      ToolCall("apply_patch", ["changes": [["path": "a.swift"]]], "Edit a.swift"),
      ToolCall("apply_patch", ["changes": [["path": "a"], ["path": "b"]]], "Edit 2 files"),
      ToolCall("apply_patch", ["changes": []], "Apply patch"),
      ToolCall("apply_patch", [:], "Apply patch"),
      ToolCall("sys_os_read", ["path": "/tmp/foo.py"], "Read /tmp/foo.py"),
      ToolCall("Read", ["file_path": "a"], "Read a"),
      ToolCall("write", ["filePath": "a"], "Write a"),
      ToolCall("edit", ["path": "a"], "Edit a"),
      ToolCall("NotebookEdit", ["notebook_path": "n"], "Edit n"),
      ToolCall("Grep", ["pattern": "x"], "Search: x"),
      ToolCall("Glob", ["pattern": "*.swift"], "Find files: *.swift"),
      ToolCall("WebSearch", ["query": "q"], "Web search: \"q\""),
      ToolCall("web_fetch", ["url": "https://a.b"], "Web fetch: https://a.b"),
      ToolCall("Task", ["description": "Look"], "Sub-agent: Look"),
      ToolCall("Task", [:], "Run sub-agent"),
      ToolCall("TodoWrite", [:], "Update todos"),
      ToolCall("sys_session_send", ["session_id": "s1"], "Send to session: s1"),
      ToolCall("sys_timer_set", [:], "Set timer"),
      ToolCall("sys_scheduled_task_create", [:], "Create scheduled task"),
      ToolCall("manage_todo_list", [:], "Manage todo list"),
      ToolCall("mcp__linear__get_issue", [:], "Get issue"),
      ToolCall("mcp__slack__slack_read_api_call", [:], "Read API call"),
      ToolCall("getPRList", [:], "Get PR list"),
    ]
    for call in cases {
      let title = ToolTitle.text(tool: call.tool, arguments: try json(call.arguments))
      #expect(title == call.expected, "\(call.tool)")
    }
  }

  @Test("arguments it can't read leave a label from the name")
  func unreadableArguments() {
    for arguments in [nil, "", "not json", "[1,2]", "{\"command\":", "{\"command\":7}"] {
      #expect(ToolTitle.text(tool: "shell", arguments: arguments) == "Shell", "\(arguments ?? "")")
    }
    #expect(ToolTitle.text(tool: "", arguments: nil).isEmpty)
    #expect(ToolTitle.text(tool: "___", arguments: nil) == "___")
    #expect(ToolTitle.text(tool: "日本語", arguments: nil) == "日本語")
  }

  @Test("only the first line shows, bounded")
  func longCommands() throws {
    let many = try json(["command": "first\nsecond"])
    #expect(ToolTitle.text(tool: "bash", arguments: many) == "$ first")
    let huge = try json(["command": String(repeating: "x", count: 100_000)])
    #expect(ToolTitle.text(tool: "bash", arguments: huge).count == 200)
  }

  @Test("the login-shell wrapper comes off only when one word follows it")
  func shellWrappers() {
    let cases = [
      ("/bin/zsh -lc ls", "ls"),
      ("bash -c 'it'\\''s'", "it's"),
      ("sh -c \"a \\\"b\\\" \\n\"", "a \"b\" \\n"),
      ("sh -c 'a' && echo 'b'", "sh -c 'a' && echo 'b'"),
      ("sh -c 'unterminated", "sh -c 'unterminated"),
      ("sh -c \"unterminated", "sh -c \"unterminated"),
      ("sh -c ''", "sh -c ''"),
      ("python -c 'x'", "python -c 'x'"),
      ("  ls  ", "ls"),
    ]
    for (command, expected) in cases {
      #expect(ToolTitle.unwrappedShellCommand(command) == expected, "\(command)")
    }
  }

  @Test("names split into server and tool, and Omnigent's own server is dropped")
  func splitting() {
    #expect(ToolTitle.split("mcp__linear__get_issue") == ("linear", "get_issue"))
    #expect(ToolTitle.split("linear__get_issue") == ("linear", "get_issue"))
    #expect(ToolTitle.split("mcp__omnigent__linear__x") == ("linear", "x"))
    #expect(ToolTitle.split("plain") == (nil, "plain"))
    #expect(ToolTitle.split("__leading") == (nil, "__leading"))
    #expect(ToolTitle.split("trailing__") == (nil, "trailing__"))
  }
}
