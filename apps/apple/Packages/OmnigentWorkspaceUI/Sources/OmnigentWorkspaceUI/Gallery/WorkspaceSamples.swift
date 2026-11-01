import Foundation

// Sample data for previews, the gallery and tests. It mirrors the recorded server responses
// in `client-core/fixtures/workspace/` as the Rust core would decode them (tree order, previews,
// grouped search results, totals, diffs with side-by-side rows).
// swiftlint:disable file_length

/// Sample workspace content.
public enum WorkspaceSamples {
  /// The sample environment root.
  public static let root = "/workspace/fixture"

  private static let modified = Date(timeIntervalSince1970: 1_793_502_799)

  /// Directory listings by path.
  public static let directories: [String: [WorkspaceEntry]] = [
    "": [
      WorkspaceEntry(path: ".git", kind: .directory, modifiedAt: modified),
      WorkspaceEntry(path: "assets", kind: .directory, modifiedAt: modified),
      WorkspaceEntry(path: "docs", kind: .directory, modifiedAt: modified),
      WorkspaceEntry(path: "src", kind: .directory, modifiedAt: modified),
      WorkspaceEntry(path: ".gitignore", kind: .file, size: 16, modifiedAt: modified),
      WorkspaceEntry(path: "build.log", kind: .file, size: 512, modifiedAt: modified),
      WorkspaceEntry(path: "README.md", kind: .file, size: 151, modifiedAt: modified),
    ],
    ".git": [],
    "assets": [
      WorkspaceEntry(path: "assets/logo.png", kind: .file, size: 165, modifiedAt: modified)
    ],
    "docs": [
      WorkspaceEntry(path: "docs/caf\u{e9} notes.md", kind: .file, size: 73, modifiedAt: modified)
    ],
    "src": [
      WorkspaceEntry(path: "src/util", kind: .directory, modifiedAt: modified),
      WorkspaceEntry(path: "src/generated.rs", kind: .file, size: 1_900_000, modifiedAt: modified),
      WorkspaceEntry(path: "src/lib.rs", kind: .file, size: 1_204, modifiedAt: modified),
      WorkspaceEntry(path: "src/main.rs", kind: .file, size: 129, modifiedAt: modified),
      WorkspaceEntry(path: "src/new_file.rs", kind: .file, size: 38, modifiedAt: modified),
    ],
    "src/util": [
      WorkspaceEntry(path: "src/util/mod.rs", kind: .file, size: 64, modifiedAt: modified)
    ],
  ]

  /// `src/main.rs` after the session's change.
  public static let mainText = """
    fn main() {
        // Fixture needle: entry point.
        println!("fixture needle says hi");
    }

    // Modified during fixture recording.

    """

  /// The text file sample.
  public static let mainFile = WorkspaceFile(
    path: "src/main.rs", byteCount: 129,
    preview: .text(TextPreview(text: mainText, lineCount: 6, language: .rust)))

  /// A longer Rust file.
  public static let libText = """
    //! Fixture library: a few helpers the agent edited.

    use std::collections::BTreeMap;

    /// A greeting for `name`.
    pub fn greet(name: &str) -> String {
        format!("Hello, {name}! The fixture needle is here.")
    }

    /// Counts words, case-insensitively.
    pub fn word_counts(text: &str) -> BTreeMap<String, usize> {
        let mut counts = BTreeMap::new();
        for word in text.split_whitespace() {
            *counts.entry(word.to_lowercase()).or_insert(0) += 1;
        }
        counts
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn greets_by_name() {
            assert_eq!(greet("Ada"), "Hello, Ada! The fixture needle is here.");
        }
    }

    """

  /// The longer Rust file sample.
  public static let libFile = WorkspaceFile(
    path: "src/lib.rs", byteCount: 1_204,
    preview: .text(TextPreview(text: libText, lineCount: 28, language: .rust)))

  /// The README sample.
  public static let readmeFile = WorkspaceFile(
    path: "README.md", byteCount: 151,
    preview: .text(
      TextPreview(
        text: """
          # Fixture workspace

          A small repository recorded for the native client's tests.

          > The fixture needle appears in several files.

          """, lineCount: 5, language: .markdown)))

  /// The base64 of the recorded 8x8 PNG.
  public static let logoBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAbElEQVR4nA3JQQEAMAgDMZSgpEqqhOepQAlKqmjLN1VFFypcTLHF"
    + "FSmqmm7UuJlmm2vSP0QLCYsRK05EP0wbGZsxa87EP4YeNHiYYYcbMj+WXrR4mWWXW7I/jj50+JhjjztyP0IHBYcJGy4kPLAsVIEx"
    + "yOP/AAAAAElFTkSuQmCC"

  /// The image sample.
  public static let logoFile = WorkspaceFile(
    path: "assets/logo.png", byteCount: 165,
    preview: .image(format: .png, data: Data(base64Encoded: logoBase64) ?? Data()))

  /// A generated file the core clipped at its preview limit.
  public static let generatedFile = WorkspaceFile(
    path: "src/generated.rs", byteCount: 1_900_000,
    preview: .text(
      TextPreview(
        text: (1...400).map { "pub const VALUE_\($0): u32 = \($0 * 7);\n" }.joined(),
        lineCount: 400, language: .rust, clipped: true)))

  /// A binary sample.
  public static let binaryFile = WorkspaceFile(
    path: "build.log", byteCount: 512, preview: .binary(reason: .nulBytes))

  /// Files by path.
  public static let files: [String: WorkspaceFile] = [
    mainFile.path: mainFile,
    libFile.path: libFile,
    readmeFile.path: readmeFile,
    logoFile.path: logoFile,
    generatedFile.path: generatedFile,
    binaryFile.path: binaryFile,
  ]

  /// The recorded content search for "fixture needle", grouped by the core.
  public static let searchResult = ContentSearchResult(files: [
    ContentSearchFile(
      path: "README.md",
      matches: [
        ContentMatch(
          path: "README.md", line: 3, column: 1,
          text: "Fixture Needle: a small repository recorded for tests.",
          match: TextRange(start: 0, end: 14)),
        ContentMatch(
          path: "README.md", line: 5, column: 7,
          text: "> The fixture needle appears in several files.",
          match: TextRange(start: 6, end: 20)),
      ]),
    ContentSearchFile(
      path: "docs/caf\u{e9} notes.md",
      matches: [
        ContentMatch(
          path: "docs/caf\u{e9} notes.md", line: 2, column: 10,
          text: "Caf\u{e9} au fixture needle, with notes.", match: TextRange(start: 8, end: 22)),
        ContentMatch(
          path: "docs/caf\u{e9} notes.md", line: 4, column: 4,
          text: "\u{1F600} fixture needle again.", match: TextRange(start: 3, end: 17)),
      ]),
    ContentSearchFile(
      path: "src/lib.rs",
      matches: [
        ContentMatch(
          path: "src/lib.rs", line: 7, column: 33,
          text: "    format!(\"Hello, {name}! The fixture needle is here.\")",
          match: TextRange(start: 32, end: 46))
      ]),
    ContentSearchFile(
      path: "src/main.rs",
      matches: [
        ContentMatch(
          path: "src/main.rs", line: 2, column: 8, text: "    // Fixture needle: entry point.",
          match: TextRange(start: 7, end: 21)),
        ContentMatch(
          path: "src/main.rs", line: 3, column: 15,
          text: "    println!(\"fixture needle says hi\");", match: TextRange(start: 14, end: 28)),
      ]),
  ])

  /// The recorded changes.
  public static let changes = ChangesList(
    files: [
      ChangedFile(path: "src/new_file.rs", status: .created, linesAdded: 2),
      ChangedFile(path: "src/main.rs", status: .modified, linesAdded: 2, linesRemoved: 0),
      ChangedFile(path: "src/lib.rs", status: .modified, linesAdded: 6, linesRemoved: 4),
      ChangedFile(path: "src/util/mod.rs", status: .deleted, linesAdded: 0, linesRemoved: 3),
    ],
    totals: ChangeTotals(created: 1, modified: 2, deleted: 1, linesAdded: 10, linesRemoved: 7))

  /// The diff of `src/main.rs`.
  public static let mainDiff = SampleDiffs.diff(
    path: "src/main.rs",
    hunks: [
      SampleDiffs.Hunk(
        old: 2, new: 2,
        lines: [
          .context("    // Fixture needle: entry point."),
          .context("    println!(\"fixture needle says hi\");"),
          .context("}"),
          .added(""),
          .added("// Modified during fixture recording."),
        ])
    ])

  /// A diff with several hunks, for navigation.
  public static let libDiff = SampleDiffs.diff(
    path: "src/lib.rs",
    hunks: [
      SampleDiffs.Hunk(
        old: 1, new: 1,
        lines: [
          .removed("//! Fixture library."),
          .added("//! Fixture library: a few helpers the agent edited."),
          .context(""),
          .context("use std::collections::BTreeMap;"),
        ]),
      SampleDiffs.Hunk(
        old: 6, new: 6, section: "pub fn greet(name: &str) -> String {",
        lines: [
          .context("pub fn greet(name: &str) -> String {"),
          .removed("    format!(\"Hello, {}!\", name)"),
          .added("    format!(\"Hello, {name}! The fixture needle is here.\")"),
          .context("}"),
        ]),
      SampleDiffs.Hunk(
        old: 10, new: 10,
        lines: [
          .removed("/// Counts words."),
          .added("/// Counts words, case-insensitively."),
          .context("pub fn word_counts(text: &str) -> BTreeMap<String, usize> {"),
          .context("    let mut counts = BTreeMap::new();"),
          .context("    for word in text.split_whitespace() {"),
          .removed("        *counts.entry(word.to_owned()).or_insert(0) += 1;"),
          .added("        *counts.entry(word.to_lowercase()).or_insert(0) += 1;"),
          .added("    }"),
          .added("    counts"),
          .context("}"),
        ]),
    ])

  /// The diff of the new file.
  public static let addedDiff = SampleDiffs.diff(
    path: "src/new_file.rs", change: .added,
    hunks: [
      SampleDiffs.Hunk(
        old: 0, new: 1,
        lines: [.added("// New during fixture recording."), .added("pub fn x() {}")])
    ])

  /// The diff of the deleted file.
  public static let deletedDiff = SampleDiffs.diff(
    path: "src/util/mod.rs", change: .deleted,
    hunks: [
      SampleDiffs.Hunk(
        old: 1, new: 0,
        lines: [.removed("pub mod util {"), .removed("    pub fn noop() {}"), .removed("}")])
    ])

  /// A diff the core could not compute.
  public static let tooLargeDiff = FileDiff(
    oldPath: "src/generated.rs", newPath: "src/generated.rs", change: .modified, hunks: [],
    splitRows: [], added: 0, removed: 0, tooLarge: true)

  /// Diffs by path.
  public static let diffs: [String: FileDiff] = [
    mainDiff.path: mainDiff,
    libDiff.path: libDiff,
    addedDiff.path: addedDiff,
    deletedDiff.path: deletedDiff,
  ]

  /// A search model that has already searched for "fixture needle".
  /// - Returns: The model.
  public static func searchedModel() -> ContentSearchModel {
    let model = ContentSearchModel(source: SampleWorkspaceDataSource())
    model.query.query = "fixture needle"
    model.restore(searchResult)
    return model
  }
}

/// Builds sample diffs in the shape the core produces. Sample data only: real diffs, their
/// line numbers and side-by-side pairing come from `omnigent_core::workspace::diff`.
enum SampleDiffs {
  enum Line {
    case context(String)
    case added(String)
    case removed(String)
  }

  struct Hunk {
    var old: UInt64
    var new: UInt64
    var section = ""
    var lines: [Line]
  }

  static func diff(path: String, change: FileChangeKind = .modified, hunks: [Hunk]) -> FileDiff {
    var built: [DiffHunk] = []
    var rows: [SplitRow] = []
    var added: UInt64 = 0
    var removed: UInt64 = 0
    for (index, hunk) in hunks.enumerated() {
      var old = max(hunk.old, 1)
      var new = max(hunk.new, 1)
      var lines: [DiffLine] = []
      for line in hunk.lines {
        switch line {
        case .context(let text):
          lines.append(DiffLine(kind: .context, oldNumber: old, newNumber: new, text: text))
          old += 1
          new += 1
        case .added(let text):
          lines.append(DiffLine(kind: .added, oldNumber: nil, newNumber: new, text: text))
          new += 1
          added += 1
        case .removed(let text):
          lines.append(DiffLine(kind: .removed, oldNumber: old, newNumber: nil, text: text))
          old += 1
          removed += 1
        }
      }
      let header = header(hunk, lines: lines)
      built.append(DiffHunk(header: header, lines: lines))
      rows.append(.hunk(index: index, header: header))
      rows.append(contentsOf: pair(lines))
    }
    return FileDiff(
      oldPath: change == .added ? nil : path, newPath: change == .deleted ? nil : path,
      change: change, hunks: built, splitRows: rows, added: added, removed: removed)
  }

  private static func header(_ hunk: Hunk, lines: [DiffLine]) -> String {
    let oldCount = lines.count { $0.kind != .added }
    let newCount = lines.count { $0.kind != .removed }
    let range = { (start: UInt64, count: Int) in count == 1 ? "\(start)" : "\(start),\(count)" }
    let section = hunk.section.isEmpty ? "" : " \(hunk.section)"
    return "@@ -\(range(hunk.old, oldCount)) +\(range(hunk.new, newCount)) @@\(section)"
  }

  private static func pair(_ lines: [DiffLine]) -> [SplitRow] {
    var rows: [SplitRow] = []
    var removed: [DiffLine] = []
    var added: [DiffLine] = []
    func flush() {
      for index in 0..<max(removed.count, added.count) {
        let left = index < removed.count ? removed[index] : nil
        let right = index < added.count ? added[index] : nil
        let spans = left.flatMap { left in right.map { changedSpans(left.text, $0.text) } }
        rows.append(
          .line(
            left: left.map { cell($0, number: $0.oldNumber, changed: spans?.0) },
            right: right.map { cell($0, number: $0.newNumber, changed: spans?.1) }))
      }
      removed = []
      added = []
    }
    for line in lines {
      switch line.kind {
      case .removed:
        if !added.isEmpty { flush() }
        removed.append(line)
      case .added: added.append(line)
      case .context:
        flush()
        rows.append(
          .line(
            left: cell(line, number: line.oldNumber, changed: nil),
            right: cell(line, number: line.newNumber, changed: nil)))
      }
    }
    flush()
    return rows
  }

  private static func cell(_ line: DiffLine, number: UInt64?, changed: TextRange?) -> SplitCell {
    SplitCell(kind: line.kind, number: number ?? 0, text: line.text, changed: changed)
  }

  private static func changedSpans(_ old: String, _ new: String) -> (TextRange, TextRange) {
    let oldBytes = Array(old.utf8)
    let newBytes = Array(new.utf8)
    var prefix = 0
    while prefix < min(oldBytes.count, newBytes.count), oldBytes[prefix] == newBytes[prefix] {
      prefix += 1
    }
    var suffix = 0
    while suffix < min(oldBytes.count, newBytes.count) - prefix,
      oldBytes[oldBytes.count - 1 - suffix] == newBytes[newBytes.count - 1 - suffix]
    {
      suffix += 1
    }
    return (
      TextRange(start: prefix, end: oldBytes.count - suffix),
      TextRange(start: prefix, end: newBytes.count - suffix)
    )
  }
}
