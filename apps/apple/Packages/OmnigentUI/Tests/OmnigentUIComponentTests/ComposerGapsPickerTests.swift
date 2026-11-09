#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import PhotosUI
  import SwiftUI
  import Testing
  import UniformTypeIdentifiers

  @testable import OmnigentUIComponents

  private struct ScriptedPhoto: PickedPhoto {
    enum Outcome {
      case data(Data)
      case nothing
      case failure(String)
    }

    var supportedContentTypes: [UTType] = [.png]
    let outcome: Outcome

    // swiftlint:disable:next async_without_await
    func loadData() async throws -> Data? {
      switch outcome {
      case .data(let data): return data
      case .nothing: return nil
      case .failure(let message):
        throw NSError(
          domain: "photo", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
      }
    }
  }

  /// A selection a test sets, as the system's photo picker does.
  @MainActor @Observable
  private final class PickerModel {
    var items: [PhotosPickerItem] = []
    var received: [[String]] = []
    var results: [AttachmentLoading.Result] = []
  }

  private struct PickerHost: View {
    @Bindable var model: PickerModel

    var body: some View {
      Color.clear.modifier(
        ComposerAttachmentPickers(
          isImporting: .constant(false), isPickingPhotos: .constant(false),
          photoItems: $model.items,
          loadPhotos: { items in
            model.received.append(items.map { $0.supportedContentTypes.map(\.identifier).joined() })
            return AttachmentLoading.Result(failures: ["read \(items.count)"])
          },
          loaded: { model.results.append($0) }))
    }
  }

  /// What the file importer and the photo picker hand back. Neither shows offscreen, so a test
  /// gives the modifier the result the system would.
  @Suite("Composer: pickers", .serialized)
  @MainActor
  struct ComposerGapsPickerTests {
    private func pickers(
      _ loaded: @escaping @MainActor (AttachmentLoading.Result) -> Void
    ) -> ComposerAttachmentPickers {
      ComposerAttachmentPickers(
        isImporting: .constant(false), isPickingPhotos: .constant(false),
        photoItems: .constant([]), loaded: loaded)
    }

    @Test("Each photo is read in turn: one with data attaches, the others say why not")
    func photoOutcomes() async {
      let bytes = Data([1, 2, 3])
      let result = await AttachmentLoading.photos([
        ScriptedPhoto(outcome: .data(bytes)),
        ScriptedPhoto(outcome: .nothing),
        ScriptedPhoto(outcome: .failure("iCloud is off")),
        ScriptedPhoto(supportedContentTypes: [], outcome: .data(bytes)),
      ])
      #expect(
        result.failures == [
          "Photo 2 has no data this app can read.", "Photo 3: iCloud is off",
        ])
      #expect(
        result.inputs == [
          .data(bytes, suggestedName: "Photo 1.png", contentType: .png),
          // A photo naming no type is read as an image, which has no file extension of its own.
          .data(bytes, suggestedName: "Photo 4.dat", contentType: .image),
        ])
    }

    @Test("No photos read to nothing")
    func noPhotos() async {
      let result = await AttachmentLoading.photos([])
      #expect(result.inputs.isEmpty)
      #expect(result.failures.isEmpty)
    }

    @Test("Picked files become attachments")
    func filesPicked() {
      var results: [AttachmentLoading.Result] = []
      let url = URL(fileURLWithPath: "/tmp/picked.txt")
      pickers { results.append($0) }.filesPicked(.success([url]))
      #expect(results.map(\.inputs) == [[.file(url: url)]])
      #expect(results.first?.failures.isEmpty == true)
    }

    @Test("A picker that fails says so")
    func filesFailed() {
      var results: [AttachmentLoading.Result] = []
      let failure = NSError(
        domain: "files", code: 1, userInfo: [NSLocalizedDescriptionKey: "No access"])
      pickers { results.append($0) }.filesPicked(.failure(failure))
      #expect(results.map(\.failures) == [["Could not open the files: No access"]])
      #expect(results.first?.inputs.isEmpty == true)
    }

    @Test("A picked photo clears the selection, so the next pick of it counts, and is read once")
    func photoSelection() async throws {
      let model = PickerModel()
      let screen = OffscreenWindow(PickerHost(model: model), width: 100, height: 100)
      defer { screen.close() }
      #expect(model.results.isEmpty, "an empty selection reads nothing")
      model.items = [PhotosPickerItem(itemIdentifier: "picked")]
      #expect(try await screen.eventually { !model.results.isEmpty })
      #expect(model.items.isEmpty)
      #expect(model.received.count == 1)
      #expect(model.results.map(\.failures) == [["read 1"]])
    }
  }
#endif
