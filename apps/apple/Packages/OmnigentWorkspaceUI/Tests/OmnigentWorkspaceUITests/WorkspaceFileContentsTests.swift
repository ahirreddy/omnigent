import Foundation
import Testing

@testable import OmnigentWorkspaceUI

/// A source without raw reads shares only what its preview holds whole.
@Suite("File contents from the preview")
struct WorkspaceFileContentsTests {
  @Test("complete text and images are the file's content")
  func completePreviews() async throws {
    let source = SampleWorkspaceDataSource()
    let text = try await source.fileContents(WorkspaceSamples.mainFile.path)
    guard case .text(let preview) = WorkspaceSamples.mainFile.preview else {
      Issue.record("the main sample is text")
      return
    }
    #expect(text.data == Data(preview.text.utf8))
    #expect(!text.truncated)
    let image = try await source.fileContents(WorkspaceSamples.logoFile.path)
    #expect(image.data == Data(base64Encoded: WorkspaceSamples.logoBase64))
  }

  @Test("clipped text and binary files are refused, not shared in part")
  func partialPreviews() async {
    let source = SampleWorkspaceDataSource()
    for path in [WorkspaceSamples.generatedFile.path, WorkspaceSamples.binaryFile.path] {
      await #expect(throws: WorkspaceFailure.self) { try await source.fileContents(path) }
    }
  }
}
