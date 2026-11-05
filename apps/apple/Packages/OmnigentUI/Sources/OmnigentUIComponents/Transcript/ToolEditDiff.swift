import Foundation

/// The change a file-edit tool call made, read from its arguments as the web's `toolEditDiff`
/// does: edit pairs and patches through ``ToolInputPreview``, and a full-file write as its
/// content, counted as added only when the output says the write created the file.
nonisolated enum ToolEditDiff {
  /// Claude `Write`, Omnigent `sys_os_write`, Pi and OpenCode `write`.
  private static let writeTools: Set = ["write", "sys_os_write"]
  private static let createdPrefixes = [
    "File created successfully at", "Created file successfully: ",
  ]

  /// The diff a call's arguments describe, or `nil` when they carry no change.
  /// - Parameters:
  ///   - tool: The tool's name.
  ///   - arguments: The call's arguments (JSON).
  ///   - output: The call's output, when it finished.
  /// - Returns: The diff.
  static func diff(tool: String, arguments: String, output: String?) -> DiffSummary? {
    if writeTools.contains(baseName(tool)) {
      return writeDiff(arguments: arguments, output: output)
    }
    return ToolInputPreview.diff(in: arguments)
  }

  /// `omnigent__write` and `mcp__server__write` name the same tool as `write`.
  private static func baseName(_ tool: String) -> String {
    let name = tool.lowercased()
    return name.components(separatedBy: "__").last ?? name
  }

  private static func writeDiff(arguments: String, output: String?) -> DiffSummary? {
    guard let data = arguments.data(using: .utf8) else { return nil }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      // A truncated argument preview: there is no content to show as a diff.
      return nil
    }
    guard let dictionary = object as? [String: Any],
      let content = dictionary["content"] as? String
    else { return nil }
    let path = ["file_path", "path", "filePath"].lazy.compactMap { dictionary[$0] as? String }
      .first
    let lines = content.isEmpty ? [] : content.components(separatedBy: "\n")
    let created = output.map(writeCreated) ?? false
    var diffLines: [DiffSummary.Line] = []
    if let path {
      diffLines.append(DiffSummary.Line(kind: .header, text: "+++ b/\(path)"))
    }
    diffLines += lines.map {
      created
        ? DiffSummary.Line(kind: .added, text: "+" + $0)
        : DiffSummary.Line(kind: .context, text: $0)
    }
    guard !diffLines.isEmpty else { return nil }
    return DiffSummary(
      files: path.map { [$0] } ?? [], added: created ? lines.count : 0, removed: 0,
      lines: diffLines)
  }

  /// Whether a write's output says the file did not exist before (Claude, OpenCode, Omnigent).
  private static func writeCreated(_ output: String) -> Bool {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if createdPrefixes.contains(where: trimmed.hasPrefix) { return true }
    return trimmed.hasPrefix("{")
      && (trimmed.contains("\"created\": true") || trimmed.contains("\"created\":true"))
  }
}
