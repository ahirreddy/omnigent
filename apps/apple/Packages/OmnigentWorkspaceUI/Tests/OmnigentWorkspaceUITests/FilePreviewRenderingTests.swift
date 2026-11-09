#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing
  import WebKit

  @testable import OmnigentWorkspaceUI

  /// What a previewable file renders as.
  @MainActor
  @Suite("File preview", .serialized)
  struct FilePreviewRenderingTests {
    private func hosted(
      _ kind: FilePreviewKind, _ text: String, renderer: WorkspaceMarkdownRenderer? = nil
    ) -> OffscreenWindow<some View> {
      OffscreenWindow(
        FilePreviewView(kind: kind, text: text).environment(\.workspaceMarkdownRenderer, renderer),
        width: 600, height: 400)
    }

    @Test("a file's extension chooses its preview, in any case")
    func kinds() {
      #expect(FilePreviewKind.of(path: "a/READ.MD") == .markdown)
      #expect(FilePreviewKind.of(path: "a.markdown") == .markdown)
      #expect(FilePreviewKind.of(path: "a.mdx") == .markdown)
      #expect(FilePreviewKind.of(path: "a.html") == .html)
      #expect(FilePreviewKind.of(path: "a.htm") == .html)
      #expect(FilePreviewKind.of(path: "a.svg") == .html)
      #expect(FilePreviewKind.of(path: "a.ipynb") == .notebook)
      #expect(FilePreviewKind.of(path: "a.rs") == nil)
      #expect(FilePreviewKind.of(path: "Makefile") == nil)
    }

    @Test("view modes have titles")
    func modes() {
      #expect(FileViewMode.allCases.map(\.title) == ["Preview", "Source", "Edit"])
      #expect(FileViewMode.edit.id == .edit)
    }

    @Test("Markdown falls back to the system's when the host has no renderer")
    func markdownFallback() throws {
      let screen = hosted(.markdown, "**Bold** words")
      defer { screen.close() }
      #expect(try screen.shows("Bold words"))
    }

    @Test("the host's renderer draws Markdown")
    func markdownRenderer() throws {
      let renderer = WorkspaceMarkdownRenderer(id: "host") { text in
        AnyView(Text("Rendered: \(text)"))
      }
      #expect(renderer == WorkspaceMarkdownRenderer(id: "host") { _ in AnyView(EmptyView()) })
      #expect(renderer != WorkspaceMarkdownRenderer(id: "other") { _ in AnyView(EmptyView()) })
      let screen = hosted(.markdown, "words", renderer: renderer)
      defer { screen.close() }
      #expect(try screen.shows("Rendered: words"))
    }

    private static let notebook = #"""
      {"cells": [
        {"cell_type": "markdown", "source": ["# Title\n", "more"]},
        {"cell_type": "code", "source": "print(1)", "outputs": [
          {"text": ["1\n"]},
          {"data": {"text/plain": "plain output"}},
          {"ename": "ValueError", "evalue": "bad"},
          {"other": true}
        ]},
        {"cell_type": "raw", "source": "raw text"},
        {"cell_type": "odd", "source": 3}
      ]}
      """#

    @Test("a notebook parses its cells and outputs")
    func notebookParsing() throws {
      let cells = try NotebookCells.parse(Self.notebook).get()
      #expect(cells.map(\.kind) == [.markdown, .code, .raw, .raw])
      #expect(cells[0].source == "# Title\nmore")
      #expect(cells[1].outputs == ["1\n", "plain output", "ValueError: bad"])
      #expect(cells[3].source.isEmpty)
    }

    @Test("a notebook that isn't one says why")
    func notebookFailures() {
      #expect(
        NotebookCells.parse("nope") == .failure(.init(message: "The notebook is not valid JSON.")))
      #expect(NotebookCells.parse("{}") == .failure(.init(message: "The notebook has no cells.")))
    }

    @Test("a notebook draws each kind of cell")
    func notebookDraws() throws {
      let screen = hosted(.notebook, Self.notebook)
      defer { screen.close() }
      for text in ["print(1)", "plain output", "ValueError: bad", "raw text"] {
        #expect(try screen.shows(text), "\(text)")
      }
    }

    @Test("a broken notebook offers the source instead")
    func notebookBroken() throws {
      let screen = hosted(.notebook, "nope")
      defer { screen.close() }
      #expect(try screen.shows("Cannot Preview Notebook"))
      #expect(try screen.shows("Show the source instead"))
    }

    @Test("HTML renders in a web view")
    func html() throws {
      let screen = hosted(.html, "<p>Hello</p>")
      defer { screen.close() }
      #expect(screen.allViews.contains { $0 is WKWebView })
    }
  }
#endif
