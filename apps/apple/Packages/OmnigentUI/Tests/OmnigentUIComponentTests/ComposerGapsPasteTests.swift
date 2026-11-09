#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing
  import UniformTypeIdentifiers

  @testable import OmnigentUIComponents

  /// Edit > Paste, which reaches SwiftUI through the hosting view, and the error it can report.
  @Suite("Composer: the Paste command", .serialized)
  @MainActor
  struct ComposerGapsPasteTests {
    private let log = ComposerActionLog()
    private static let file = URL(fileURLWithPath: "/tmp/pasted.txt")

    init() {
      SystemSideEffects.reset()
    }

    private func clipboardFile() {
      let pasteboard = SystemSideEffects.pasteboard
      pasteboard.clearContents()
      pasteboard.setString(Self.file.absoluteString, forType: .fileURL)
    }

    private func clipboardBadImage() {
      let pasteboard = SystemSideEffects.pasteboard
      pasteboard.clearContents()
      pasteboard.setData(Data([1, 2, 3]), forType: .tiff)
    }

    private func paste<Content>(_ screen: OffscreenWindow<Content>) async {
      _ = screen.host.tryToPerform(#selector(NSText.paste(_:)), with: nil)
      await screen.drainTasks()
    }

    @Test("Paste attaches a copied file")
    func composerPastesFile() async throws {
      let screen = openComposer(ComposerScreenModel(state: ComposerViewState()), log.actions)
      defer { screen.close() }
      clipboardFile()
      await paste(screen)
      #expect(try await screen.eventually { !log.attachments.isEmpty })
      #expect(log.attachments == [.file(url: Self.file)])
    }

    @Test("Paste attaches a copied file in the CLI composer")
    func cliPastesFile() async throws {
      let screen = try cliComposerScreen(ComposerViewState(), actions: log.actions)
      defer { screen.close() }
      screen.focusEditor()
      clipboardFile()
      await paste(screen)
      #expect(try await screen.eventually { !log.attachments.isEmpty })
      #expect(log.attachments == [.file(url: Self.file)])
    }

    @Test("An image that can't be read is reported in the CLI composer, and can be dismissed")
    func cliReportsUnreadable() async throws {
      let screen = try cliComposerScreen(ComposerViewState(), actions: log.actions)
      defer { screen.close() }
      screen.focusEditor()
      clipboardBadImage()
      await paste(screen)
      #expect(try await screen.eventually { try screen.shows("could not be read as an image") })
      #expect(log.attachments.isEmpty)
      // The banner's Copy, then its Dismiss.
      try screen.tapButton(1)
      #expect(try await screen.eventually { try !screen.shows("could not be read as an image") })
    }

    @Test("The CLI composer says why it can't take a paste")
    func cliSaysWhyNot() async throws {
      var actions = log.actions
      actions.addAttachments = nil
      let screen = try cliComposerScreen(ComposerViewState(), actions: actions)
      defer { screen.close() }
      screen.focusEditor()
      clipboardFile()
      await paste(screen)
      #expect(try await screen.eventually { try screen.shows("can't take attachments") })
    }
  }

  /// The keys and VoiceOver actions on the editors that no other suite reaches.
  @Suite("Composer: editor actions", .serialized)
  @MainActor
  struct ComposerGapsEditorActionTests {
    private let log = ComposerActionLog()

    init() {
      SystemSideEffects.reset()
    }

    @Test("VoiceOver's Expand Editor gives the editor more room, and Collapse takes it back")
    func expandFromVoiceOver() throws {
      let screen = openComposer(ComposerScreenModel(state: ComposerViewState()), log.actions)
      defer { screen.close() }
      let scroll = try #require(screen.textView?.enclosingScrollView)
      let usual = scroll.frame.height
      try screen.withAccessibilityTree {
        let editor = try screen.accessibilityElement("composer-input")
        let expand = try screen.customAction("Expand Editor", of: editor)
        #expect(expand.handler?() == true)
        screen.settle(0.3)
        #expect(scroll.frame.height > usual)
        let expanded = try screen.accessibilityElement("composer-input")
        let collapse = try screen.customAction("Collapse Editor", of: expanded)
        #expect(collapse.handler?() == true)
        screen.settle(0.3)
        #expect(scroll.frame.height == usual)
      }
    }

    @Test("Up in an empty CLI composer recalls the previous prompt; Down goes back")
    func cliArrowsRecall() throws {
      log.prompts = ["earlier prompt"]
      var actions = log.actions
      actions.extras.history = log.history
      let screen = try cliComposerScreen(ComposerViewState(), actions: actions)
      defer { screen.close() }
      screen.focusEditor()
      let editor = try #require(screen.textView)
      try screen.pressUp()
      #expect(editor.string == "earlier prompt")
      try screen.pressDown()
      #expect(editor.string.isEmpty)
    }
  }

  /// The Mac's own dictation, for a host without a dictate action.
  @Suite("Composer: system dictation", .serialized)
  @MainActor
  struct ComposerGapsDictationTests {
    private let log = ComposerActionLog()

    init() {
      SystemSideEffects.reset()
      DictationStub.install()
      DictationStub.count = 0
    }

    private func composer() -> (OffscreenWindow<ComposerScreen>, ComposerActions) {
      var actions = log.actions
      actions.extras.dictate = nil
      return (openComposer(ComposerScreenModel(state: ComposerViewState()), actions), actions)
    }

    @Test("Mic starts dictation in the focused editor")
    func startsInTheEditor() async throws {
      let (screen, _) = composer()
      defer { screen.close() }
      #expect(screen.window.firstResponder is NSTextView)
      try screen.tapButton(0)
      #expect(try await screen.eventually { DictationStub.count == 1 })
      #expect(screen.window.firstResponder is NSTextView)
      #expect(try !screen.shows("Dictation is unavailable"))
    }

    @Test("With nothing to take dictation, Mic says how to turn it on")
    func reportsUnavailable() async throws {
      let (screen, _) = composer()
      defer { screen.close() }
      DictationStub.isAccepted = false
      defer { DictationStub.isAccepted = true }
      try screen.tapButton(0)
      #expect(try await screen.eventually { try screen.shows("Dictation is unavailable") })
    }
  }
#endif
