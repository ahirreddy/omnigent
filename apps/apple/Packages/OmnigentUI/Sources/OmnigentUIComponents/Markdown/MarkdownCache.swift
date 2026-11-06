import Foundation
import OmnigentPlatform
import Synchronization

/// Parsed markdown keyed by its text, shared by every view and the background warm-up
/// (``MarkdownWarmup``), so scrolling re-parses nothing and a row's first render usually finds
/// its blocks parsed. Thread-safe; a miss parses outside the lock, so a reader never waits for
/// another thread's parse.
nonisolated final class MarkdownCache: Sendable {
  static let shared = MarkdownCache(limit: 1024)

  private let entries: Mutex<BoundedCache<String, [MarkdownBlock]>>

  init(limit: Int) {
    entries = Mutex(BoundedCache(limit: limit))
  }

  /// How many texts the cache holds.
  var limit: Int { entries.withLock { $0.capacity } }

  /// Whether `text` is parsed already.
  func contains(_ text: String) -> Bool {
    entries.withLock { $0.cached(text) != nil }
  }

  /// The blocks of `text`, parsed on a miss.
  func blocks(for text: String) -> [MarkdownBlock] {
    if let cached = entries.withLock({ $0.cached(text) }) { return cached }
    let parsed = PerformanceSignposts.measure(PerformanceSignposts.transcript, "markdown parse") {
      MarkdownParser.parse(text)
    }
    entries.withLock { $0.store(parsed, for: text) }
    return parsed
  }
}

/// Code spans keyed by code and language, shared by both transcript styles and the warm-up.
/// Tokenizing is the costly half of highlighting; coloring the spans is linear.
nonisolated final class CodeSpanCache: Sendable {
  static let shared = CodeSpanCache(limit: 512)

  private struct Key: Hashable {
    var code: String
    var language: String?
  }

  private let entries: Mutex<BoundedCache<Key, [CodeSpan]>>

  init(limit: Int) {
    entries = Mutex(BoundedCache(limit: limit))
  }

  /// Whether `code` is tokenized already.
  func contains(_ code: String, language: String?) -> Bool {
    let key = Key(code: code, language: CodeHighlighting.fenceName(language))
    return entries.withLock { $0.cached(key) != nil }
  }

  /// The colored spans of `code`, tokenized on a miss.
  func spans(_ code: String, language: String?) -> [CodeSpan] {
    let key = Key(code: code, language: CodeHighlighting.fenceName(language))
    if let cached = entries.withLock({ $0.cached(key) }) { return cached }
    let spans = PerformanceSignposts.measure(PerformanceSignposts.transcript, "code tokenize") {
      CodeHighlighting.spans(code, language: language)
    }
    entries.withLock { $0.store(spans, for: key) }
    return spans
  }
}

/// Parses settled messages' markdown and tokenizes their code off the main actor, newest
/// first, so the transcript's rows find both cached when they first render. Each row's text is
/// handed over once; a streaming row waits until it settles.
@MainActor
final class MarkdownWarmup {
  private var handed: Set<Handed> = []
  private var lastFirstID: String?
  private var lastCount = 0
  private var task: Task<Void, Never>?
  /// How many texts were handed to the background, for tests.
  private(set) var handedCount = 0

  private struct Handed: Hashable {
    var id: String
    var length: Int
  }

  /// Hands over the rows whose text renders as markdown and is not streaming, newest first. A
  /// paged-in or reset list is scanned whole; otherwise only the last few rows can be new.
  /// - Returns: A task that ends once the newest ``firstScreen`` texts handed now are prepared;
  ///   `nil` when nothing new was handed.
  @discardableResult
  func warm(_ rows: [Row]) -> Task<Void, Never>? {
    let isSameList = rows.first?.id == lastFirstID && rows.count == lastCount
    lastFirstID = rows.first?.id
    lastCount = rows.count
    let scanned = isSameList ? rows.suffix(4) : rows[...]
    var texts: [String] = []
    let room = MarkdownCache.shared.limit / 2
    for row in scanned.reversed() where texts.count < room && Self.rendersMarkdown(row) {
      if handed.insert(Handed(id: row.id, length: row.text.utf8.count)).inserted {
        texts.append(row.text)
      }
    }
    guard !texts.isEmpty else { return nil }
    handedCount += texts.count
    let previous = task
    let first = Array(texts.prefix(Self.firstScreen))
    let rest = Array(texts.dropFirst(Self.firstScreen))
    let head = Task.detached(priority: .userInitiated) {
      await previous?.value
      Self.prepare(first)
    }
    if rest.isEmpty {
      task = head
    } else {
      task = Task.detached(priority: .utility) {
        await head.value
        Self.prepare(rest)
      }
    }
    return head
  }

  /// Waits until everything handed over so far is prepared, for tests.
  func settle() async {
    await task?.value
  }

  /// About as many answers as one screen shows when a conversation opens.
  static let firstScreen = 12

  /// Assistant answers render their text as markdown; user prompts render a cleaned copy.
  private static func rendersMarkdown(_ row: Row) -> Bool {
    row.role == .assistant && !row.isStreaming && !row.text.isEmpty
  }

  nonisolated private static func prepare(_ texts: [String]) {
    for text in texts { prepare(text) }
  }

  /// Parses `text` and tokenizes the code blocks it holds.
  nonisolated static func prepare(_ text: String) {
    tokenize(MarkdownCache.shared.blocks(for: text))
  }

  nonisolated private static func tokenize(_ blocks: [MarkdownBlock]) {
    for block in blocks {
      switch block {
      case .code(let language, let code) where CodeHighlighting.supports(language):
        _ = CodeSpanCache.shared.spans(code, language: language)
      case .quote(let inner): tokenize(inner)
      case .list(_, _, let items):
        for item in items { tokenize(item.blocks) }
      default: break
      }
    }
  }
}
