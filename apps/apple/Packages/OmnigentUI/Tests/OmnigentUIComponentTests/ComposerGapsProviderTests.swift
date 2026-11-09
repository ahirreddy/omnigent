#if os(macOS)
  import AppKit
  import Testing
  import UniformTypeIdentifiers

  @testable import OmnigentUIComponents

  /// An item provider that answers as a misbehaving source can, which NSItemProvider's own
  /// registration can't produce.
  nonisolated private final class ScriptedProvider: NSItemProvider, @unchecked Sendable {
    var types: [UTType] = []
    var image: NSImage?
    var offersImage = false
    var failure: (any Error)?

    override var registeredContentTypes: [UTType] { types }

    override func hasItemConformingToTypeIdentifier(_ typeIdentifier: String) -> Bool { false }

    override func canLoadObject(ofClass aClass: any NSItemProviderReading.Type) -> Bool {
      offersImage
    }

    // What the Swift overlay's `loadDataRepresentation(for:)` calls.
    override func __loadDataRepresentation(
      forContentType contentType: UTType,
      completionHandler: @escaping @Sendable (Data?, (any Error)?) -> Void
    ) -> Progress {
      completionHandler(nil, nil)
      return Progress()
    }

    override func loadObject(
      ofClass aClass: any NSItemProviderReading.Type,
      completionHandler: @escaping @Sendable ((any NSItemProviderReading)?, (any Error)?) -> Void
    ) -> Progress {
      completionHandler(image, failure)
      return Progress()
    }
  }

  @Suite("Composer: item providers")
  @MainActor
  struct ComposerGapsProviderTests {
    private func redDot() -> NSImage {
      NSImage(size: CGSize(width: 2, height: 2), flipped: false) { rect in
        NSColor.red.setFill()
        rect.fill()
        return true
      }
    }

    @Test("A representation that gives neither data nor an error is named as empty")
    func emptyRepresentation() async throws {
      let provider = ScriptedProvider()
      provider.types = [.png]
      provider.suggestedName = "Shot"
      do {
        _ = try await ItemProviderLoader.load(provider, index: 0)
        Issue.record("loaded an empty representation")
      } catch {
        #expect(error.localizedDescription.contains("Shot could not be read as an image"))
        #expect(error.localizedDescription.contains("Shot had no data."))
      }
    }

    @Test("Where no representation works, the provider's image object is sent as PNG")
    func imageObject() async throws {
      let provider = ScriptedProvider()
      provider.offersImage = true
      provider.image = redDot()
      let input = try await ItemProviderLoader.load(provider, index: 2)
      guard case .data(let data, let name, let type) = input else {
        Issue.record("not data: \(input)")
        return
      }
      #expect(name == "Pasted item 3.png")
      #expect(type == .png)
      #expect(NSImage(data: data) != nil)
    }

    @Test("An image object that doesn't arrive is reported, not dropped")
    func imageObjectMissing() async {
      let provider = ScriptedProvider()
      provider.offersImage = true
      do {
        _ = try await ItemProviderLoader.load(provider, index: 0)
        Issue.record("loaded nothing")
      } catch {
        #expect(error.localizedDescription.contains("had no data"))
      }
    }

    @Test("A provider's own error about the image object is passed on")
    func imageObjectFails() async {
      let provider = ScriptedProvider()
      provider.offersImage = true
      provider.failure = NSError(
        domain: "image", code: 1, userInfo: [NSLocalizedDescriptionKey: "Source went away"])
      do {
        _ = try await ItemProviderLoader.load(provider, index: 0)
        Issue.record("loaded nothing")
      } catch {
        #expect(error.localizedDescription.contains("Source went away"))
      }
    }
  }
#endif
