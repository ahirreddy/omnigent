#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing
  import UniformTypeIdentifiers

  @testable import OmnigentUIComponents

  /// Pasting an image into the editor with Command-V, and what the loader makes of each item.
  @Suite("Composer: paste", .serialized)
  @MainActor
  struct ComposerPasteTests {
    private let log = ComposerActionLog()

    private static func png() throws -> Data {
      let image = NSImage(size: CGSize(width: 2, height: 2), flipped: false) { rect in
        NSColor.red.setFill()
        rect.fill()
        return true
      }
      let tiff = try #require(image.tiffRepresentation)
      let bitmap = try #require(NSBitmapImageRep(data: tiff))
      return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func pressCommandV(_ screen: OffscreenWindow<ComposerScreen>) async throws {
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
          windowNumber: screen.window.windowNumber, context: nil, characters: "v",
          charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
      NSApp.sendEvent(event)
      await screen.drainTasks()
    }

    private func clipboard(
      _ data: Data?, type: NSPasteboard.PasteboardType = .png, text: String? = nil
    ) {
      SystemSideEffects.reset()
      let pasteboard = SystemSideEffects.pasteboard
      pasteboard.clearContents()
      let item = NSPasteboardItem()
      if let data { item.setData(data, forType: type) }
      if let text { item.setString(text, forType: .string) }
      pasteboard.writeObjects([item])
    }

    @Test("Command-V with an image on the clipboard attaches it")
    func pastesImage() async throws {
      let screen = openComposer(ComposerScreenModel(state: ComposerViewState()), log.actions)
      defer { screen.close() }
      clipboard(try Self.png())
      try await pressCommandV(screen)
      #expect(log.attachments.count == 1)
      if case .data(_, let name, let type)? = log.attachments.first {
        #expect(name == "Pasted item 1.png")
        #expect(type == .png)
      } else {
        Issue.record("not data: \(log.attachments)")
      }
    }

    @Test("an image that can't be read reports it, and the report can be dismissed")
    func unreadableImage() async throws {
      let screen = openComposer(ComposerScreenModel(state: ComposerViewState()), log.actions)
      defer { screen.close() }
      clipboard(Data([1, 2, 3]), type: .tiff)
      try await pressCommandV(screen)
      #expect(log.attachments.isEmpty)
      #expect(try screen.shows("could not be read as an image"))
      // The banner's Copy, then its Dismiss.
      try screen.tapButton(1)
      #expect(try !screen.shows("could not be read as an image"))
    }

    @Test("a composer that takes no attachments says so instead of attaching")
    func notAccepting() async throws {
      var state = ComposerViewState()
      state.acceptsAttachments = false
      let screen = openComposer(ComposerScreenModel(state: state), log.actions)
      defer { screen.close() }
      clipboard(try Self.png())
      try await pressCommandV(screen)
      #expect(log.attachments.isEmpty)
      #expect(try screen.shows("can't take attachments right now."))
    }

    @Test("text on the clipboard is left for the editor to paste")
    func textStaysText() async throws {
      let screen = openComposer(ComposerScreenModel(state: ComposerViewState()), log.actions)
      defer { screen.close() }
      clipboard(nil, text: "words")
      try await pressCommandV(screen)
      #expect(log.attachments.isEmpty)
    }

    @Test("an image with long text beside it stays text; with a link it attaches")
    func shouldAttach() throws {
      let png = try Self.png()
      clipboard(png, text: "a whole sentence here")
      #expect(!PasteboardImages.shouldAttach(SystemSideEffects.pasteboard))
      clipboard(png, text: "https://example.com/a.png")
      #expect(PasteboardImages.shouldAttach(SystemSideEffects.pasteboard))
      clipboard(png, text: "   ")
      #expect(PasteboardImages.shouldAttach(SystemSideEffects.pasteboard))
      clipboard(nil, text: "words")
      #expect(!PasteboardImages.shouldAttach(SystemSideEffects.pasteboard))
    }

    @Test("one provider per item with an image; a promise not kept names its format")
    func providers() throws {
      clipboard(try Self.png())
      #expect(PasteboardImages.providers(SystemSideEffects.pasteboard).count == 1)
      clipboard(nil, text: "words")
      #expect(PasteboardImages.providers(SystemSideEffects.pasteboard).isEmpty)
      let missing = PasteboardImages.MissingRepresentation(format: "public.png")
      #expect(missing.localizedDescription == "the pasteboard did not give its public.png data")
    }

    // MARK: The loader

    @Test("a file URL item loads as that file")
    func fileItem() async throws {
      let url = URL(filePath: "/tmp/a.txt")
      let provider = NSItemProvider()
      provider.registerDataRepresentation(for: .fileURL, visibility: .all) { done in
        done(url.dataRepresentation, nil)
        return nil
      }
      let result = try await ItemProviderLoader.load(provider, index: 0)
      if case .file(let loaded) = result {
        #expect(loaded == url)
      } else {
        Issue.record("not a file: \(result)")
      }
    }

    @Test("an item that isn't a file or image, or is empty, fails naming it")
    func badItems() async throws {
      let text = NSItemProvider()
      text.suggestedName = "Notes"
      await #expect(throws: ItemProviderLoader.LoadError.self) {
        _ = try await ItemProviderLoader.load(text, index: 0)
      }
      let result = await AttachmentLoading.providers([text])
      #expect(result.failures == ["Notes is not a file or an image."])
      #expect(result.inputs.isEmpty)
      #expect(ItemProviderLoader.LoadError.empty("A").localizedDescription == "A had no data.")
    }

    @Test("TIFF becomes PNG; a representation that fails falls through to report every reason")
    func imageItems() async throws {
      let rep = try #require(NSBitmapImageRep(data: try Self.png()))
      let tiff = try #require(rep.tiffRepresentation)
      let provider = NSItemProvider()
      provider.registerDataRepresentation(for: .tiff, visibility: .all) { done in
        done(tiff, nil)
        return nil
      }
      let loaded = await AttachmentLoading.providers([provider])
      if case .data(_, let name, let type)? = loaded.inputs.first {
        #expect(type == .png)
        #expect(name == "Pasted item 1.png")
      } else {
        Issue.record("not data: \(loaded)")
      }

      let broken = NSItemProvider()
      broken.suggestedName = "Shot"
      broken.registerDataRepresentation(for: .png, visibility: .all) { done in
        done(nil, PasteboardImages.MissingRepresentation(format: "public.png"))
        return nil
      }
      let failed = await AttachmentLoading.providers([broken])
      #expect(failed.failures.count == 1)
      #expect(failed.failures.first?.hasPrefix("Shot could not be read as an image") == true)
    }

    @Test("an image object with no raw data is saved as PNG")
    func imageObject() async throws {
      let image = try #require(NSImage(data: try Self.png()))
      let provider = NSItemProvider(object: image)
      let result = await AttachmentLoading.providers([provider])
      #expect(result.failures.isEmpty)
      #expect(result.inputs.count == 1)
    }

    @Test("why a paste attached nothing includes the composer's reason")
    func unavailableReason() {
      #expect(
        AttachmentLoading.unavailable("Archived")
          == "This conversation can't take attachments right now. Archived")
      #expect(
        AttachmentLoading.unavailable(nil) == "This conversation can't take attachments right now.")
    }
  }
#endif
