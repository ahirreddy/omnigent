#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentWorkspaceUI
  import Testing

  @testable import OmnigentAppUI

  /// The Mac's Download: a save panel, then the whole file, wherever the session runs.
  @MainActor
  @Suite("Workspace download", .serialized, .timeLimit(.minutes(1)))
  struct WorkspaceDownloadTests {
    private final class Reports {
      var messages: [String] = []
    }

    private func folder() throws -> URL {
      let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      return folder
    }

    @Test("Download saves the file where the save panel points")
    func savesWhereChosen() async throws {
      SystemSideEffects.install()
      SystemSideEffects.reset()
      let destination = try folder().appending(path: "picked.rs")
      SystemSideEffects.answer(panel: .OK, panelURL: destination)
      let reports = Reports()
      let source = SampleWorkspaceDataSource()
      let path = WorkspaceSamples.mainFile.path
      await WorkspaceFileSaver.save(path, from: source) { reports.messages.append($0) }
      #expect(reports.messages.isEmpty)
      #expect(SystemSideEffects.record.panelCount == 1)
      let expected = try await source.download(path).data
      #expect(FileManager.default.contents(atPath: destination.path) == expected)
      SystemSideEffects.reset()
    }

    @Test("Cancel saves nothing, and a failed download says which file")
    func cancelAndFailure() async throws {
      SystemSideEffects.install()
      SystemSideEffects.reset()
      let destination = try folder().appending(path: "never.rs")
      SystemSideEffects.answer(panel: .cancel, panelURL: destination)
      let reports = Reports()
      await WorkspaceFileSaver.save("a/file", from: EndlessDirectory()) {
        reports.messages.append($0)
      }
      #expect(!FileManager.default.fileExists(atPath: destination.path))
      #expect(reports.messages.isEmpty, "a cancelled panel downloads nothing")

      await WorkspaceFileSaver.download("a/file", from: EndlessDirectory(), to: destination) {
        reports.messages.append($0)
      }
      #expect(reports.messages.count == 1)
      #expect(reports.messages.first?.hasPrefix("file could not be downloaded") == true)
      #expect(!FileManager.default.fileExists(atPath: destination.path))
      SystemSideEffects.reset()
    }

    @Test("Download is offered for a session on another machine, as for this Mac's")
    func offeredForRemoteHosts() {
      let source = EndlessDirectory()
      source.root = "/not/on/this/mac"
      let remote = WorkspaceActionsAdapter.actions(
        WorkspaceBrowserModel(source: source), mention: nil, report: { _ in })
      #expect(remote.download != nil)
      #expect(remote.reveal == nil)
    }
  }
#endif
