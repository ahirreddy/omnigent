import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import OmnigentWorkspaceUI

/// The lines a review suggestion replaces, as the web's `reviewSuggestionSource`: the range in
/// the diff on screen, or the comment's own snippet once the code moved on.
extension ReviewThreadsAdapter {
  /// The source for `thread`'s suggestions; `nil` when no comment suggests anything or the
  /// lines can't be read whole.
  /// - Parameters:
  ///   - thread: The conversation.
  ///   - file: Its file's diff at the revision shown; `nil` when read at another one.
  /// - Returns: The lines and where they start.
  static func suggestionSource(_ thread: ReviewThread, file: OmnigentWorkspaceUI.FileDiff?)
    -> PullRequestSuggestionSource?
  {
    guard thread.comments.comments.contains(where: { $0.body.contains("suggestion") }),
      !thread.onFile, let side = thread.side, thread.startSide == nil || thread.startSide == side
    else { return nil }
    let old = side == .left
    if let file, !thread.outdated, let end = thread.line,
      file.path == thread.path || file.oldPath == thread.path
    {
      let start = thread.startLine ?? end
      let lines = lines(in: file, old: old, from: start, to: end)
      if !lines.isEmpty {
        return PullRequestSuggestionSource(line: start, lines: lines, original: false)
      }
    }
    guard let end = thread.originalLine, !thread.diffHunk.isEmpty else { return nil }
    let start = thread.originalStartLine ?? end
    let hunk = thread.diffHunk.hasSuffix("\n") ? thread.diffHunk : thread.diffHunk + "\n"
    let patch = "diff --git a/review b/review\n--- a/review\n+++ b/review\n\(hunk)"
    guard let parsed = try? parseUnifiedDiff(patch: patch).first else { return nil }
    let lines = lines(in: WorkspaceMapping.fileDiff(parsed), old: old, from: start, to: end)
    guard !lines.isEmpty else { return nil }
    return PullRequestSuggestionSource(line: start, lines: lines, original: true)
  }

  /// Lines `start` through `end` of one side of `file`; none unless the diff holds them all.
  static func lines(
    in file: OmnigentWorkspaceUI.FileDiff, old: Bool, from start: UInt64, to end: UInt64
  ) -> [String] {
    guard start >= 1, end >= start else { return [] }
    var byNumber: [UInt64: String] = [:]
    for line in file.hunks.flatMap(\.lines) {
      let number = old ? line.oldNumber : line.newNumber
      guard let number, (start...end).contains(number),
        old ? line.kind != .added : line.kind != .removed
      else { continue }
      byNumber[number] = line.text
    }
    let lines = (start...end).compactMap { byNumber[$0] }
    return lines.count == Int(end - start + 1) ? lines : []
  }
}
