#if os(macOS)
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import UniformTypeIdentifiers
  import Testing
  import WebKit

  @testable import OmnigentUIComponents

  @Suite("Markdown edge cases")
  @MainActor
  struct MarkdownEdgeCaseTests {
    @Test("A spacing command or an environment in math reads as text")
    func mathCommands() {
      #expect(!MathText.unicode("a\\,b").contains("\\"))
      #expect(MathText.unicode("\\begin{cases}x\\end{cases}") == "x")
      #expect(MathText.unicode("\\%").contains("%"))
    }

    @Test("A write's output says whether it created the file")
    func writeCreatedOutput() throws {
      let arguments = #"{"file_path":"a.txt","content":"hello"}"#
      let created = try #require(
        ToolEditDiff.diff(tool: "Write", arguments: arguments, output: #"{"created":true}"#))
      #expect(created.added == 1)
      let overwritten = try #require(
        ToolEditDiff.diff(tool: "Write", arguments: arguments, output: #"{"created":false}"#))
      #expect(overwritten.added == 0)
      let plain = try #require(
        ToolEditDiff.diff(tool: "Write", arguments: arguments, output: "Saved"))
      #expect(plain.added == 0)
    }

    @Test("A code span's backticks don't count as math, however many runs it holds")
    func mathInsideCode() {
      let preserved = "`` a ` $x$ `` and `b"
      #expect(MarkdownMath.delimited(preserved).contains("$x$"))
      #expect(!MarkdownMath.delimited("see $$x$$ here").contains("$$"))
    }

    // A save panel from .fileExporter presents nothing off screen: the VM flows cover it.
    @Test("Download on a code block starts an export without leaving the transcript")
    func codeDownload() throws {
      let screen = transcriptScreen(CodeBlockDownloadButton(code: "let a = 1", language: "swift"))
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("Two exports are told apart by their name and text")
    func exportIdentity() {
      let base = TextExport(text: "a", name: "table.csv", type: .commaSeparatedText)
      #expect(base.id == TextExport(text: "a", name: "table.csv", type: .plainText).id)
      #expect(base.id != TextExport(text: "b", name: "table.csv", type: .plainText).id)
      #expect(base.id != TextExport(text: "a", name: "table.md", type: .plainText).id)
    }

    @Test("Diagrams render again after the web content process ends")
    func renderAfterCrash() async throws {
      let renderer = RichBlockRenderer.shared
      let request = RichBlockRequest(kind: .math(display: true, size: 15), source: "x")
      _ = try await renderer.render(request)
      renderer.webViewWebContentProcessDidTerminate(WKWebView())
      let again = try await renderer.render(request)
      #expect(again.size.width > 0)
    }

    @Test("A navigation failure with no load waiting does nothing")
    func navigationFailureWithoutLoad() {
      let renderer = RichBlockRenderer.shared
      let error = CocoaError(.fileReadCorruptFile)
      renderer.webView(WKWebView(), didFail: nil, withError: error)
      renderer.webView(WKWebView(), didFailProvisionalNavigation: nil, withError: error)
    }

    @Test("An equation still streaming reads as text rather than typesetting")
    func openEquationStaysText() throws {
      let screen = transcriptScreen(
        MathBlockView(tex: "x^2").environment(\.markdownBlockIsOpen, true))
      defer { screen.close() }
      #expect(try screen.shows("x\u{00B2}"))
    }

    @Test("A cited workspace file opens in the app, once its folder's listing shows it")
    func citedFileOpens() async throws {
      var listed: [String] = []
      var opened: [WorkspaceFileTarget] = []
      let links = WorkspaceFileLinks(
        root: { "/home/u/ws" }, home: { "/home/u" },
        listFolder: { folder in
          listed.append(folder)
          return WorkspaceFolderListing(files: ["a.ts"])
        },
        open: { opened.append($0) })
      let screen = transcriptScreen(
        MarkdownView("[src/a.ts](src/a.ts)").environment(\.workspaceFileLinks, links))
      defer { screen.close() }
      try await letTasksRun(screen)
      #expect(listed == ["src"])
      try screen.click(CGPoint(x: 12, y: 10))
      #expect(opened == [WorkspaceFileTarget(path: "src/a.ts")])
    }
  }
#endif
