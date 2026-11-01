import Foundation
public import OmnigentCoreFFI
public import OmnigentWorkspaceUI

/// Maps the core's workspace records onto the workspace views' records. Pure; no logic beyond
/// field-by-field conversion (the core computes order, previews and diffs).
nonisolated public enum WorkspaceMapping {
  static func kind(_ kind: WorkspaceErrorKind) -> WorkspaceFailure.Kind {
    switch kind {
    case .notConnected: .notConnected
    case .invalidInput: .invalidInput
    case .notFound: .notFound
    case .notChanged: .notChanged
    case .unavailable: .unavailable
    case .forbidden: .forbidden
    case .runnerOffline: .runnerOffline
    case .searchDisabled: .searchDisabled
    case .searchFailed: .searchFailed
    case .server: .server
    }
  }

  static func date(_ seconds: Int64?) -> Date? {
    seconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
  }

  static func entry(_ entry: OmnigentCoreFFI.WorkspaceEntry)
    -> OmnigentWorkspaceUI.WorkspaceEntry
  {
    let kind: OmnigentWorkspaceUI.WorkspaceEntryKind =
      switch entry.kind {
      case .file: .file
      case .directory: .directory
      case .symlink: .symlink
      case .other: .other
      case .unknown(let value): .unknown(value)
      }
    return OmnigentWorkspaceUI.WorkspaceEntry(
      path: entry.path, name: entry.name, kind: kind, size: entry.size,
      modifiedAt: date(entry.modifiedAt))
  }

  static func status(_ status: WorkspaceChangeStatus)
    -> OmnigentWorkspaceUI.ChangeStatus
  {
    switch status {
    case .created: .created
    case .modified: .modified
    case .deleted: .deleted
    case .unknown(let value): .unknown(value)
    }
  }

  static func preview(_ preview: OmnigentCoreFFI.FilePreview)
    -> OmnigentWorkspaceUI.FilePreview
  {
    switch preview {
    case .text(let text):
      return .text(textPreview(text))
    case .image(let format, let data):
      return .image(format: imageFormat(format), data: data)
    case .binary(let reason, _):
      let mapped: OmnigentWorkspaceUI.BinaryReason =
        switch reason {
        case .notText: .notText
        case .nulBytes: .nulBytes
        case .truncatedImage: .truncatedImage
        }
      return .binary(reason: mapped)
    }
  }

  static func textPreview(_ text: OmnigentCoreFFI.TextPreview) -> OmnigentWorkspaceUI.TextPreview {
    let ending: OmnigentWorkspaceUI.LineEnding =
      switch text.lineEnding {
      case .lf: .lf
      case .crLf: .crlf
      case .mixed: .mixed
      }
    return OmnigentWorkspaceUI.TextPreview(
      text: text.text, lineCount: text.lineCount, lineEnding: ending,
      language: text.language.flatMap(language), skipHighlighting: text.skipHighlighting,
      clipped: text.clipped, serverTruncated: text.serverTruncated)
  }

  static func imageFormat(_ format: OmnigentCoreFFI.ImageFormat)
    -> OmnigentWorkspaceUI.ImageFormat
  {
    switch format {
    case .png: .png
    case .jpeg: .jpeg
    case .gif: .gif
    case .webp: .webp
    case .bmp: .bmp
    case .tiff: .tiff
    case .heic: .heic
    case .ico: .ico
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  static func language(_ language: OmnigentCoreFFI.SyntaxLanguage)
    -> OmnigentWorkspaceUI.SyntaxLanguage?
  {
    switch language {
    case .bash: .bash
    case .c: .c
    case .cpp: .cpp
    case .cSharp: .csharp
    case .css: .css
    case .dockerfile: .dockerfile
    case .go: .go
    case .html: .html
    case .java: .java
    case .javaScript: .javascript
    case .json: .json
    case .kotlin: .kotlin
    case .makefile: .makefile
    case .markdown: .markdown
    case .objectiveC: .objectiveC
    case .php: .php
    case .python: .python
    case .ruby: .ruby
    case .rust: .rust
    case .scala: .scala
    case .sql: .sql
    case .swift: .swift
    case .toml: .toml
    case .typeScript: .typescript
    case .xml: .xml
    case .yaml: .yaml
    }
  }

  static func lineKind(_ kind: OmnigentCoreFFI.DiffLineKind)
    -> OmnigentWorkspaceUI.DiffLineKind
  {
    switch kind {
    case .context: .context
    case .added: .added
    case .removed: .removed
    }
  }

  static func cell(_ cell: OmnigentCoreFFI.SplitCell?)
    -> OmnigentWorkspaceUI.SplitCell?
  {
    cell.map { cell in
      OmnigentWorkspaceUI.SplitCell(
        kind: lineKind(cell.kind), number: cell.number, text: cell.text,
        changed: cell.changed.map {
          OmnigentWorkspaceUI.TextRange(start: Int($0.start), end: Int($0.end))
        })
    }
  }

  /// The diff view's record for a core diff.
  /// - Parameter diff: The core's diff.
  /// - Returns: The view record.
  public static func fileDiff(_ diff: OmnigentCoreFFI.FileDiff)
    -> OmnigentWorkspaceUI.FileDiff
  {
    let change: OmnigentWorkspaceUI.FileChangeKind =
      switch diff.change {
      case .added: .added
      case .deleted: .deleted
      case .modified: .modified
      case .renamed: .renamed
      case .copied: .copied
      }
    return OmnigentWorkspaceUI.FileDiff(
      oldPath: diff.oldPath, newPath: diff.newPath, change: change,
      hunks: diff.hunks.map { hunk in
        OmnigentWorkspaceUI.DiffHunk(
          header: hunk.header,
          lines: hunk.lines.map { line in
            OmnigentWorkspaceUI.DiffLine(
              kind: lineKind(line.kind), oldNumber: line.oldNumber, newNumber: line.newNumber,
              text: line.text, missingNewline: line.missingNewline)
          })
      },
      splitRows: diff.splitRows.map { row in
        switch row {
        case .hunk(let index, let header): .hunk(index: Int(index), header: header)
        case .line(let left, let right): .line(left: cell(left), right: cell(right))
        }
      },
      added: diff.added, removed: diff.removed, binary: diff.binary,
      approximate: diff.approximate, tooLarge: diff.tooLarge)
  }
}
