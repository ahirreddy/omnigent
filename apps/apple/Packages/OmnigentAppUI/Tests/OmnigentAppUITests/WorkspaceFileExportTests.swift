import Foundation
import OmnigentWorkspaceUI
import Testing

@testable import OmnigentAppUI

/// Workspace files copied locally for the share sheet and Quick Look (iPhone and iPad).
@MainActor
struct WorkspaceFileExportTests {
  private let export = WorkspaceFileExport(
    directory: FileManager.default.temporaryDirectory.appending(
      path: "WorkspaceFileExportTests-\(UUID().uuidString)", directoryHint: .isDirectory))

  @Test func aCopyKeepsTheFileNameAndBytes() throws {
    defer { removeDirectory() }
    let bytes = Data([0x25, 0x50, 0x44, 0x46, 0x00, 0xFF])
    let file = try export.write(WorkspaceFileContents(path: "docs/report.pdf", data: bytes))

    #expect(file.lastPathComponent == "report.pdf")
    #expect(try Data(contentsOf: file) == bytes)
  }

  @Test func eachCopyReplacesTheLastOne() throws {
    defer { removeDirectory() }
    let first = try export.write(WorkspaceFileContents(path: "a.txt", data: Data("a".utf8)))
    let second = try export.write(WorkspaceFileContents(path: "a.txt", data: Data("b".utf8)))

    #expect(first != second)
    #expect(!FileManager.default.fileExists(atPath: first.path(percentEncoded: false)))
    #expect(try String(contentsOf: second, encoding: .utf8) == "b")
  }

  @Test func aTruncatedFileIsNotSharedAsIfWhole() {
    defer { removeDirectory() }
    let contents = WorkspaceFileContents(path: "big.bin", data: Data([1]), truncated: true)

    #expect(throws: WorkspaceFileExport.Failure.truncated(name: "big.bin")) {
      try export.write(contents)
    }
  }

  @Test func pathsWithoutAUsableNameGetAStandIn() {
    #expect(WorkspaceFileExport.fileName(of: "src/main.rs") == "main.rs")
    #expect(WorkspaceFileExport.fileName(of: "") == "file")
  }

  private func removeDirectory() {
    do {
      try FileManager.default.removeItem(at: export.directory)
    } catch CocoaError.fileNoSuchFile {
      // Nothing was written.
    } catch {
      Issue.record("cleaning up failed: \(error)")
    }
  }
}
