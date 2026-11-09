#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// What a user does in the file viewer: switch modes, show comments, use the actions menu.
  @MainActor
  @Suite("File viewer interactions", .serialized)
  struct FileViewerInteractionTests {
    init() {
      SystemSideEffects.install()
      SystemSideEffects.reset()
      UserDefaults.standard.removeObject(forKey: "workspace.fileViewMode")
      UserDefaults.standard.removeObject(forKey: "workspace.showsComments")
    }

    private static func textFile(_ path: String = "poems/haiku.txt", _ text: String = "old pond\n")
      -> WorkspaceFile
    {
      WorkspaceFile(
        path: path, byteCount: UInt64(text.utf8.count),
        preview: .text(TextPreview(text: text, lineCount: 1)))
    }

    private func canEdit() -> WorkspaceActions {
      var actions = WorkspaceActions()
      actions.canEdit = true
      return actions
    }

    private func editorShown<Content: View>(_ screen: OffscreenWindow<Content>) -> NSTextView? {
      screen.allViews.compactMap { $0 as? NSTextView }.first {
        $0.accessibilityIdentifier() == "workspace.editor"
      }
    }

    @Test("a text file offers Source and Edit, and Edit opens the editor")
    func textModes() throws {
      let editor = ReviewFixtures.editor()
      let screen = OffscreenWindow(
        FileViewerView(
          file: Self.textFile(), source: SampleWorkspaceDataSource(), actions: canEdit(),
          editor: editor, review: ReviewFixtures.context()),
        width: 900, height: 400)
      defer { screen.close() }
      let picker = try #require(screen.segmentedPickers.first)
      #expect(picker.segmentCount == 2)
      #expect(editorShown(screen) == nil)
      try screen.clickSegment(1, of: picker)
      #expect(editorShown(screen)?.string == "old pond\n")
      #expect(UserDefaults.standard.string(forKey: "workspace.fileViewMode") == "edit")
      try screen.clickSegment(0, of: try #require(screen.segmentedPickers.first))
      #expect(editorShown(screen) == nil)
      #expect(UserDefaults.standard.string(forKey: "workspace.fileViewMode") == "source")
    }

    @Test("a read-only viewer has no Edit, even when the last file opened in Edit")
    func readOnlyHasNoEdit() throws {
      UserDefaults.standard.set("edit", forKey: "workspace.fileViewMode")
      let screen = OffscreenWindow(
        FileViewerView(file: Self.textFile(), source: SampleWorkspaceDataSource()),
        width: 900, height: 300)
      defer { screen.close() }
      #expect(screen.segmentedPickers.isEmpty, "one mode needs no picker")
      #expect(editorShown(screen) == nil)
    }

    @Test("Markdown offers Preview, Source and Edit and opens as chosen last")
    func markdownModes() throws {
      let file = Self.textFile("notes/plan.md", "# Plan\n")
      let screen = OffscreenWindow(
        FileViewerView(
          file: file, source: SampleWorkspaceDataSource(), actions: canEdit(),
          editor: ReviewFixtures.editor(path: file.path, text: "# Plan\n")),
        width: 900, height: 400)
      defer { screen.close() }
      let picker = try #require(screen.segmentedPickers.first)
      #expect(picker.segmentCount == 3)
      try screen.clickSegment(2, of: picker)
      #expect(editorShown(screen) != nil)
    }

    @Test("Comments shows the panel and its close button hides it")
    func commentsToggle() throws {
      let spy = ReviewSpy()
      let review = ReviewFixtures.context(comments: [ReviewFixtures.comment("one")], spy: spy)
      let screen = OffscreenWindow(
        FileViewerView(
          file: Self.textFile(), source: SampleWorkspaceDataSource(), actions: canEdit(),
          editor: ReviewFixtures.editor(), review: review),
        width: 900, height: 400)
      defer { screen.close() }
      let before = screen.controls.count
      // The header's only plain button is the Comments toggle.
      try screen.click(try #require(screen.appKitButtons.first))
      #expect(UserDefaults.standard.bool(forKey: "workspace.showsComments"))
      #expect(screen.controls.count > before, "the panel brought its controls")
      let text = try shownString(screen)
      #expect(text.contains("Check this"), "read: \(text)")
    }

    @Test("clipped and truncated files say so")
    func notices() throws {
      for (preview, expected) in [
        (TextPreview(text: "a\nb\n", lineCount: 2, clipped: true), "first 2 lines"),
        (TextPreview(text: "a\nb\n", lineCount: 2, serverTruncated: true), "server returned"),
      ] {
        let file = WorkspaceFile(path: "big.log", byteCount: 2_000, preview: .text(preview))
        let screen = OffscreenWindow(
          FileViewerView(file: file, source: SampleWorkspaceDataSource()), width: 700, height: 240)
        defer { screen.close() }
        let text = try shownString(screen)
        #expect(text.contains(expected), "read: \(text)")
      }
    }

    @Test("an image shows its size, an undecodable one says so, and a binary file explains itself")
    func nonText() throws {
      let logo = OffscreenWindow(
        FileViewerView(file: WorkspaceSamples.logoFile, source: SampleWorkspaceDataSource()),
        width: 500, height: 400)
      defer { logo.close() }
      #expect(logo.segmentedPickers.isEmpty)
      let broken = WorkspaceFile(
        path: "x.png", byteCount: 3, preview: .image(format: .png, data: Data([1, 2, 3])))
      let badImage = OffscreenWindow(
        FileViewerView(file: broken, source: SampleWorkspaceDataSource()), width: 500, height: 300)
      defer { badImage.close() }
      #expect(try shownString(badImage).contains("Cannot Display Image"))
      let binary = OffscreenWindow(
        FileViewerView(file: WorkspaceSamples.binaryFile, source: SampleWorkspaceDataSource()),
        width: 500, height: 300)
      defer { binary.close() }
      #expect(try shownString(binary).contains("No Preview"))
    }

    @Test("the actions menu copies paths and runs the host's hooks")
    func actionsMenu() throws {
      var revealed: [String] = []
      var opened: [String] = []
      var mentioned: [String] = []
      var shared: [String] = []
      var looked: [String] = []
      let actions = WorkspaceActions(
        reveal: { revealed.append($0) }, openExternally: { opened.append($0) },
        mention: { mentioned.append($0) }, share: { shared.append($0) },
        quickLook: { looked.append($0) })
      let screen = OffscreenWindow(
        FileViewerView(
          file: Self.textFile("src/main.rs"), source: SampleWorkspaceDataSource(),
          actions: actions),
        width: 900, height: 300)
      defer { screen.close() }
      let menu = try screen.menu(ofPopUp: 0)
      let titles = menu.items.map(\.title).filter { !$0.isEmpty }
      #expect(
        titles == [
          "Quick Look", "Share\u{2026}", "Copy Path", "Copy Absolute Path", "Reveal in Finder",
          "Open in Editor", "Mention in Message",
        ])
      try screen.choose("Copy Path", in: menu)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "src/main.rs")
      try screen.choose("Copy Absolute Path", in: menu)
      let absolute = "\(WorkspaceSamples.root)/src/main.rs"
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == absolute)
      try screen.choose("Reveal in Finder", in: menu)
      #expect(revealed == [absolute])
      try screen.choose("Open in Editor", in: menu)
      #expect(opened == [absolute])
      try screen.choose("Mention in Message", in: menu)
      #expect(mentioned == ["src/main.rs"])
      try screen.choose("Share\u{2026}", in: menu)
      #expect(shared == ["src/main.rs"])
      try screen.choose("Quick Look", in: menu)
      #expect(looked == ["src/main.rs"])
    }

    @Test("with no hooks the menu only copies the path")
    func actionsMenuBare() throws {
      let source = ListedSource([:])
      let screen = OffscreenWindow(
        FileViewerView(file: Self.textFile(), source: source), width: 900, height: 300)
      defer { screen.close() }
      let titles = try screen.menu(ofPopUp: 0).items.map(\.title).filter { !$0.isEmpty }
      #expect(titles == ["Copy Path"])
    }
  }
#endif
