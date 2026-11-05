import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("Uploaded image previews")
@MainActor
struct AttachmentPreviewTests {
  static let bytes = Data([1, 2, 3])

  /// A 96x60 PNG: a blue field with a lighter band.
  static let samplePNG = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAGAAAAA8CAIAAAAWtijjAAAAcUlEQVR42u3XMREAIAwAsWpCE2JRUhvgoBtLm7tXkO1j7aOiQ"
      + "AAIECBAgAABAiRAgAABAgQIECABAgQIECBALYAyr4oAAQIECBAgQIAACRCgH0B21M0DAgQIECBAgAQIECBAgAABAiR"
      + "AgAABAgQI0IAeBoIvrGrehNsAAAAASUVORK5CYII=")

  private final class Reads {
    var references: [String] = []
  }

  @Test("each reference is read once and cached")
  func readsOnce() async throws {
    let reads = Reads()
    let previews = AttachmentPreviews { reference in
      reads.references.append(reference)
      return Self.bytes
    }
    async let first = previews.data(for: "file_1")
    async let second = previews.data(for: "file_1")
    #expect(try await first == Self.bytes)
    #expect(try await second == Self.bytes)
    _ = try await previews.data(for: "file_1")
    #expect(reads.references == ["file_1"])
  }

  @Test("a failed read is not cached")
  func failureRetries() async {
    struct Offline: Error {}
    let reads = Reads()
    let previews = AttachmentPreviews { reference in
      reads.references.append(reference)
      throw Offline()
    }
    await #expect(throws: Offline.self) { try await previews.data(for: "file_1") }
    await #expect(throws: Offline.self) { try await previews.data(for: "file_1") }
    #expect(reads.references.count == 2)
  }

  @Test("only uploaded images preview; embedded bytes and files stay chips")
  func previewable() {
    #expect(
      Attachment(id: "a", kind: .image, title: "a.png", reference: "file_1").previewableImage
        == "file_1")
    #expect(
      Attachment(id: "b", kind: .image, title: "b.png", isEmbedded: true).previewableImage == nil)
    #expect(
      Attachment(id: "c", kind: .file, title: "c.pdf", reference: "file_2").previewableImage
        == nil)
  }

  #if os(macOS)
    @Test("a user message shows its uploaded image above the text")
    func render() async throws {
      let png = try #require(Self.samplePNG)
      let previews = AttachmentPreviews { _ in png }
      _ = try await previews.data(for: "file_1")
      let row = Row(
        id: "user", role: .user, text: "What is in this screenshot?",
        attachments: [
          Attachment(id: "a", kind: .image, title: "screen.png", reference: "file_1"),
          Attachment(id: "b", kind: .file, title: "notes.pdf", reference: "file_2"),
        ])
      let rendered = try RenderSupport.render(
        MessageRowView(row: row, decoration: MessageDecoration())
          .environment(\.attachmentPreviews, previews).padding(),
        width: 720, scheme: .light, layout: .regular)
      try RenderSupport.write(rendered, name: "message-attachments")
      #expect(rendered.size.height > 120)
    }
  #endif
}
