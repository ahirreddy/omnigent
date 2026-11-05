import Foundation
import OmnigentWorkspaceUI
import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("Code block highlighting")
@MainActor
struct CodeHighlightingTests {
  private func tokens(_ code: String, _ language: String?) -> [(CodeToken, String)] {
    let units = Array(code.utf16)
    return CodeHighlighting.spans(code, language: language).map {
      ($0.token, String(decoding: units[$0.range], as: UTF16.self))
    }
  }

  @Test("fence names pick the shared highlighter's language")
  func languages() {
    #expect(
      tokens("let x = 1 // hi", "swift").map(\.0) == [
        .syntax(.keyword), .syntax(.number), .syntax(.comment),
      ])
    #expect(tokens("const a = 'b'", "ts title=app.ts").map(\.1) == ["const", "'b'"])
    #expect(tokens("anything goes", "brainfuck").isEmpty)
    #expect(tokens("let x = 1", nil).isEmpty)
    #expect(CodeHighlighting.supports("PY") && !CodeHighlighting.supports("mermaid"))
  }

  @Test("diffs color added, removed and header lines")
  func diff() {
    let found = tokens("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n same", "diff")
    #expect(found.map(\.0) == [.header, .header, .header, .deleted, .inserted])
    #expect(found.map(\.1) == ["--- a/x", "+++ b/x", "@@ -1 +1 @@", "-old", "+new"])
  }

  @Test("the cache colors known languages and leaves others plain")
  func cache() throws {
    let cache = CodeHighlightCache(limit: 4)
    #expect(cache.attributed("x", language: "text", scheme: .dark) == nil)
    let colored = try #require(cache.attributed("let x", language: "swift", scheme: .light))
    #expect(colored.runs.contains { $0.foregroundColor != nil })
    #expect(String(colored.characters) == "let x")
  }
}

@Suite("Workspace paths in messages")
@MainActor
struct WorkspacePathTests {
  @Test("citations split their position off the path")
  func citations() {
    #expect(WorkspacePaths.citation("src/a.ts:12:5").path == "src/a.ts")
    #expect(WorkspacePaths.citation("src/a.ts:12:5").line == 12)
    #expect(WorkspacePaths.citation("src/a.ts:12:5").column == 5)
    #expect(WorkspacePaths.citation("notes.md:12-18").line == 12)
    #expect(WorkspacePaths.citation("lib.rs#L40C2").path == "lib.rs")
    #expect(WorkspacePaths.citation("lib.rs#L40C2").column == 2)
    #expect(WorkspacePaths.citation("README.md").line == nil)
  }

  @Test("inline code links only when it reads as a path")
  func pathShape() {
    #expect(WorkspacePaths.looksLikeRelativePath("src/components/App.tsx"))
    #expect(WorkspacePaths.looksLikeRelativePath("docs/Design Notes.md"))
    #expect(!WorkspacePaths.looksLikeRelativePath("git diff src/app"))
    #expect(!WorkspacePaths.looksLikeRelativePath("useState"))
    #expect(!WorkspacePaths.looksLikeRelativePath("../etc/passwd"))
    #expect(!WorkspacePaths.looksLikeRelativePath("a//b"))
    #expect(!WorkspacePaths.looksLikeRelativePath("https://x.test/a"))
    #expect(WorkspacePaths.mayCite("/ws/src/a.ts:3"))
    #expect(!WorkspacePaths.mayCite("/usr/bin/env python"))
  }

  @Test("absolute and home paths resolve only inside the workspace root")
  func resolution() {
    let root = "/home/u/ws/"
    #expect(WorkspacePaths.resolve("src/a.ts", root: nil, home: nil) == "src/a.ts")
    #expect(WorkspacePaths.resolve("/home/u/ws/src/a.ts", root: root, home: nil) == "src/a.ts")
    #expect(WorkspacePaths.resolve("~/ws/a.md", root: root, home: "/home/u") == "a.md")
    #expect(WorkspacePaths.resolve("/etc/hosts", root: root, home: nil) == nil)
    #expect(WorkspacePaths.resolve("/home/u/ws", root: root, home: nil) == nil)
    #expect(WorkspacePaths.resolve("/home/u/ws/../x", root: root, home: nil) == nil)
    #expect(WorkspacePaths.resolve("/home/u/ws/a.ts", root: nil, home: nil) == nil)
    #expect(WorkspacePaths.resolve("C:\\x", root: root, home: nil) == nil)
  }

  @Test("link destinations: file paths and file URLs, not web URLs or anchors")
  func destinations() {
    #expect(WorkspacePaths.linkedPath("src/My%20File.md") == "src/My File.md")
    #expect(WorkspacePaths.linkedPath("notes.md:12") == "notes.md:12")
    #expect(WorkspacePaths.linkedPath("file:///ws/a.ts#L3") == "/ws/a.ts#L3")
    #expect(WorkspacePaths.linkedPath("mailto:x@y.z") == nil)
    #expect(WorkspacePaths.linkedPath("#section") == nil)
    #expect(WorkspacePaths.linkedPath("//cdn.test/x") == nil)
  }

  @Test("an in-app file link round-trips through its URL")
  func targetURL() throws {
    let target = WorkspaceFileTarget(path: "src/a b.ts", line: 4, column: 2)
    let url = try #require(target.url)
    #expect(WorkspaceFileTarget(url: url) == target)
    #expect(WorkspaceFileTarget(url: try #require(URL(string: "https://x.test"))) == nil)
  }

  @Test("the parser tags path-shaped inline code and file links, never web links")
  func parsing() {
    guard
      case .paragraph(let text)? = MarkdownParser.parse(
        "See `src/a.ts:3`, `npm test`, [the doc](docs/x.md) and [site](https://x.test)."
      ).first
    else {
      Issue.record("expected a paragraph")
      return
    }
    let tagged = text.runs.compactMap { run in
      run[WorkspacePathAttribute.self].map { ($0, run[WorkspacePathIsExplicitAttribute.self]) }
    }
    #expect(tagged.map(\.0) == ["src/a.ts:3", "docs/x.md"])
    #expect(tagged.map(\.1) == [nil, true])
    #expect(text.runs.compactMap(\.link).map(\.absoluteString) == ["https://x.test"])
  }
}

@Suite("Workspace file links")
@MainActor
struct WorkspaceFileLinksTests {
  private final class Probe {
    var listed: [String] = []
    var opened: [WorkspaceFileTarget] = []
  }

  private func links(_ probe: Probe, files: [String: Set<String>]) -> WorkspaceFileLinks {
    WorkspaceFileLinks(
      root: { "/ws" }, home: nil,
      listFiles: { folder in
        probe.listed.append(folder)
        guard let names = files[folder] else { throw URLError(.fileDoesNotExist) }
        return names
      },
      open: { probe.opened.append($0) })
  }

  @Test("a path links once its folder listing shows the file, listing each folder once")
  func existence() async {
    let probe = Probe()
    let links = links(probe, files: ["src": ["a.ts", "b.ts"], "": ["README.md"]])
    let cited = [
      CitedPath(text: "src/a.ts:3", explicit: false), CitedPath(text: "src/b.ts", explicit: false),
      CitedPath(text: "src/missing.ts", explicit: false),
      CitedPath(text: "README.md", explicit: true), CitedPath(text: "lib/x.rs", explicit: false),
    ]
    #expect(links.target(for: "src/a.ts:3", explicit: false) == nil, "unchecked paths stay text")
    await links.check(cited)
    await links.check(cited)
    #expect(probe.listed == ["", "lib", "src"])
    #expect(links.target(for: "src/a.ts:3", explicit: false) == .init(path: "src/a.ts", line: 3))
    #expect(links.target(for: "/ws/src/b.ts", explicit: false)?.path == "src/b.ts")
    #expect(links.target(for: "src/missing.ts", explicit: false) == nil)
    #expect(links.target(for: "README.md", explicit: true)?.path == "README.md")
    #expect(links.target(for: "README.md", explicit: false) == nil, "bare names need a link")
    #expect(links.target(for: "lib/x.rs", explicit: false) == nil)
    #expect(links.failures["lib"] != nil, "a failed listing is kept, not dropped")
  }

  @Test("linking sets in-app URLs, and the open action routes them to the host")
  func opening() async throws {
    let probe = Probe()
    let links = links(probe, files: ["src": ["a.ts"]])
    var text = AttributedString("src/a.ts")
    text[WorkspacePathAttribute.self] = "src/a.ts:9"
    await links.check(MarkdownBlock.citedPaths(in: [.paragraph(text)]))
    let url = try #require(links.linking(text).runs.first?.link)
    var external: [URL] = []
    let action = links.openURLAction(
      fallback: OpenURLAction {
        external.append($0)
        return .handled
      })
    action(url)
    action(try #require(URL(string: "https://x.test")))
    #expect(probe.opened == [WorkspaceFileTarget(path: "src/a.ts", line: 9)])
    #expect(external.map(\.absoluteString) == ["https://x.test"])
  }
}

@Suite("Markdown images and math")
@MainActor
struct MarkdownImagesAndMathTests {
  @Test("an image alone in its paragraph from the workspace or a data URL is an image block")
  func images() {
    #expect(
      MarkdownParser.parse("![arch](docs/arch.png)") == [
        .image(source: "docs/arch.png", alt: "arch")
      ])
    let data = "data:image/png;base64,iVBORw0KGgo="
    #expect(MarkdownParser.parse("![dot](\(data))") == [.image(source: data, alt: "dot")])
    if case .paragraph? = MarkdownParser.parse("![svg](data:image/svg+xml;base64,PHN2Zz4=)").first {
    } else {
      Issue.record("an SVG data URL is never decoded")
    }
    if case .paragraph? = MarkdownParser.parse("Text ![a](docs/a.png)").first {
    } else {
      Issue.record("an image inside prose stays inline text")
    }
  }

  @Test("display and inline math, as the web delimits them")
  func math() {
    #expect(MarkdownParser.parse("$$\nx^2 + 1\n$$") == [.math("x^2 + 1")])
    #expect(MarkdownParser.parse("Before\n\\[\n\\alpha\n\\]\nafter").count == 3)
    #expect(MarkdownParser.parse("$$E = mc^2$$") == [.math("E = mc^2")])
    guard
      case .paragraph(let text)? = MarkdownParser.parse("Area \\(\\pi r^2\\) costs $5 or $6.").first
    else {
      Issue.record("expected a paragraph")
      return
    }
    #expect(String(text.characters) == "Area π r² costs $5 or $6.")
    #expect(text.runs.contains { $0[MathSpanAttribute.self] == "\\pi r^2" })
  }

  @Test("code keeps its math delimiters verbatim")
  func codeUntouched() {
    #expect(MarkdownParser.parse("```\n$$x$$\n```") == [.code(language: nil, code: "$$x$$")])
    guard case .paragraph(let text)? = MarkdownParser.parse("Run `echo \\(x\\)` now").first else {
      Issue.record("expected a paragraph")
      return
    }
    #expect(String(text.characters) == "Run echo \\(x\\) now")
    #expect(MarkdownMath.delimited("costs $5 and $6") == "costs $5 and $6")
  }

  @Test("TeX draws as Unicode")
  func unicode() {
    #expect(MathText.unicode("\\alpha + \\beta \\leq \\infty") == "α + β ≤ ∞")
    #expect(MathText.unicode("x^{2} + y_1") == "x² + y₁")
    #expect(MathText.unicode("\\frac{a+b}{2}") == "(a+b)/2")
    #expect(MathText.unicode("\\sqrt{x}") == "√x")
    #expect(MathText.unicode("e^{i\\pi}") == "e^(iπ)")
    #expect(MathText.unicode("\\mathbb{R}^n") == "ℝⁿ")
    #expect(MathText.unicode("\\unknown{x}") == "\\unknownx")
  }

  @Test("a streamed reply with math matches a whole parse")
  func streaming() {
    let reply = "Intro\n\n$$\na^2\n$$\n\nThen \\(b\\) and\n\n```swift\nlet x = 1\n```\n"
    let memo = MarkdownRenderMemo()
    var streamed: [MarkdownBlock] = []
    for end in reply.indices.dropFirst() {
      streamed = memo.blocks(for: String(reply[..<end]), isStreaming: true)
    }
    streamed = memo.blocks(for: reply, isStreaming: true)
    #expect(streamed == MarkdownParser.parse(reply))
  }
}
