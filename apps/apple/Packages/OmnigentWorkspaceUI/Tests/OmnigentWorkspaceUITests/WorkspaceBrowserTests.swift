#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// The browser: the panel's tabs and shortcuts, and the document's states.
  @MainActor
  @Suite("Workspace browser", .serialized)
  struct WorkspaceBrowserTests {
    init() {
      SystemSideEffects.install()
      SystemSideEffects.reset()
      UserDefaults.standard.removeObject(forKey: "workspace.fileViewMode")
      UserDefaults.standard.removeObject(forKey: "workspace.showsComments")
    }

    private func shortcut<Content: View>(
      _ screen: OffscreenWindow<Content>, _ key: String, _ code: UInt16,
      _ modifiers: NSEvent.ModifierFlags
    ) throws -> Bool {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: screen.window.windowNumber,
        context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
        keyCode: code)
      return screen.window.performKeyEquivalent(with: try #require(event))
    }

    @Test("the tabs switch between Files, Search and Changes")
    func tabs() async throws {
      let model = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
      let screen = OffscreenWindow(WorkspacePanel(model: model), width: 340, height: 480)
      defer { screen.close() }
      let picker = try #require(screen.segmentedPickers.first)
      #expect(picker.segmentCount == WorkspaceTab.allCases.count)
      try screen.clickSegment(1, of: picker)
      #expect(model.tab == .search)
      await flush(screen)
      #expect(try screen.shows("Search File Contents"))
      try screen.clickSegment(2, of: picker)
      #expect(model.tab == .changes)
      #expect(await settle(screen) { model.changes.state.value != nil })
      await flush(screen)
      #expect(try screen.shows("changed"))
      try screen.clickSegment(0, of: picker)
      #expect(model.tab == .files)
      #expect(WorkspaceTab.allCases.map(\.title) == ["Files", "Search", "Changes"])
      #expect(WorkspaceTab.allCases.map(\.symbol) == ["folder", "magnifyingglass", "plusminus"])
      #expect(WorkspaceTab.files.id == "files")
    }

    @Test("Command-Shift-F opens Search; Command-Option-1 to 3 pick tabs")
    func shortcuts() throws {
      let model = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
      let screen = OffscreenWindow(WorkspacePanel(model: model), width: 340, height: 480)
      defer { screen.close() }
      #expect(try shortcut(screen, "f", 3, [.command, .shift]))
      #expect(model.tab == .search)
      #expect(try shortcut(screen, "3", 20, [.command, .option]))
      #expect(model.tab == .changes)
      #expect(try shortcut(screen, "1", 18, [.command, .option]))
      #expect(model.tab == .files)
    }

    @Test("opening a changed file from the panel shows its diff")
    func opensFromChanges() async throws {
      let model = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
      model.tab = .changes
      let screen = OffscreenWindow(
        WorkspaceBrowserView(model: model), width: 1_100, height: 500)
      defer { screen.close() }
      #expect(try screen.shows("No File Selected"))
      #expect(await settle(screen) { model.changes.state.value != nil })
      let path = try #require(model.changes.state.value?.files.first?.path)
      await flush(screen)
      model.changes.selection = path
      #expect(await settle(screen) { model.diff.value?.path == path })
      await flush(screen)
      #expect(try screen.shows("change"))
      #expect(try !screen.shows("No File Selected"))
    }

    @Test("a compact width pushes the document over the panel")
    func compact() async throws {
      let model = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
      let screen = OffscreenWindow(
        WorkspaceBrowserView(model: model).environment(\.horizontalSizeClass, .compact),
        width: 390, height: 500)
      defer { screen.close() }
      await flush(screen)
      #expect(try !screen.shows("No File Selected"), "no document beside the panel")
      await model.open(.file(path: WorkspaceSamples.readmeFile.path, line: nil))
      await flush(screen)
      #expect(model.document != nil)
    }

    private func document(
      _ model: WorkspaceBrowserModel, actions: WorkspaceActions = .none
    ) -> OffscreenWindow<WorkspaceDocumentView> {
      OffscreenWindow(
        WorkspaceDocumentView(model: model, actions: actions), width: 760, height: 480)
    }

    @Test("a file that can't be read offers Try Again, which reads it again")
    func fileFailure() async throws {
      let path = WorkspaceSamples.mainFile.path
      let source = SampleWorkspaceDataSource(
        failures: [path: WorkspaceFailure(.notFound, message: "It went away")])
      let model = WorkspaceBrowserModel(source: source)
      await model.open(.file(path: path, line: nil))
      #expect(model.file.failure != nil)
      let screen = document(model)
      defer { screen.close() }
      #expect(try screen.shows("It went away"))
      #expect(try screen.shows("Not Found"))
      source.failures = [:]
      let retry = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: retry.midX, y: retry.midY))
      #expect(await settle(screen) { model.file.value != nil })
    }

    @Test("a diff that can't be read offers Try Again; loading shows neither")
    func diffFailure() async throws {
      let path = WorkspaceSamples.mainDiff.path
      let source = SampleWorkspaceDataSource(
        failures: [path: WorkspaceFailure(.server, message: "Bad diff")])
      let model = WorkspaceBrowserModel(source: source)
      await model.open(.diff(path: path))
      let screen = document(model)
      defer { screen.close() }
      #expect(try screen.shows("Could Not Load"))
      #expect(try screen.shows("Bad diff"))
      source.failures = [:]
      let retry = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: retry.midX, y: retry.midY))
      #expect(await settle(screen) { model.diff.value != nil })
    }

    /// A browser with one file open and edited, asking whether to save it.
    private func askingToClose() async throws -> (WorkspaceBrowserModel, FileEditor) {
      let model = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
      let opened = WorkspaceDocument.file(path: WorkspaceSamples.mainFile.path, line: nil)
      await model.open(opened)
      let editor = try #require(model.editors[WorkspaceSamples.mainFile.path])
      editor.autosaveDelay = nil
      editor.text = "edited\n"
      await model.close(opened)
      #expect(model.pendingClose == opened)
      return (model, editor)
    }

    @Test("closing an edited file asks; Save saves and closes")
    func closeSaves() async throws {
      let (model, _) = try await askingToClose()
      SystemSideEffects.answer(alert: .alertFirstButtonReturn)
      let screen = document(model)
      defer { screen.close() }
      #expect(await settle(screen) { model.openDocuments.isEmpty })
      let messages = SystemSideEffects.record.alertMessages
      #expect(messages.contains { $0.contains("main.rs") }, "\(messages)")
      #expect(model.pendingClose == nil)
    }

    @Test("Don't Save puts the old text back and closes")
    func closeDiscards() async throws {
      let (model, editor) = try await askingToClose()
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      let screen = document(model)
      defer { screen.close() }
      #expect(await settle(screen) { model.openDocuments.isEmpty })
      #expect(!editor.isDirty)
    }

    @Test("Cancel keeps the file open with its edit")
    func closeCancels() async throws {
      let (model, editor) = try await askingToClose()
      SystemSideEffects.answer(alert: .alertThirdButtonReturn)
      let screen = document(model)
      defer { screen.close() }
      #expect(await settle(screen) { model.pendingClose == nil })
      #expect(model.openDocuments.count == 1)
      #expect(editor.isDirty)
    }

    @Test("a viewer who can only read gets no review; one who can edit gets comments")
    func review() async throws {
      let model = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
      await model.open(.file(path: WorkspaceSamples.mainFile.path, line: nil))
      let reader = document(model)
      defer { reader.close() }
      #expect(try !reader.shows("Comments"))
      var editing = WorkspaceActions()
      editing.canEdit = true
      let editor = document(model, actions: editing)
      defer { editor.close() }
      #expect(editor.segmentedPickers.first?.segmentCount == 2, "Source and Edit")
      #expect(!editor.appKitButtons.isEmpty)
    }

    @Test("unsaved edits are listed across browsers, saved or discarded")
    func unsavedEdits() async throws {
      let model = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
      await model.open(.file(path: WorkspaceSamples.mainFile.path, line: nil))
      let editor = try #require(model.editors[WorkspaceSamples.mainFile.path])
      editor.autosaveDelay = nil
      editor.text = "edited\n"
      #expect(UnsavedFileEdits.paths.contains(editor.path))
      UnsavedFileEdits.discardAll()
      #expect(!editor.isDirty)
      editor.text = "edited again\n"
      let left = await UnsavedFileEdits.saveAll()
      #expect(!left.contains(editor.path))
      #expect(UnsavedFileEdits.title(for: ["src/a.rs"]) == "Save changes to \u{201C}a.rs\u{201D}?")
      #expect(UnsavedFileEdits.title(for: ["a", "b"]) == "Save changes to 2 files?")
    }
  }
#endif
