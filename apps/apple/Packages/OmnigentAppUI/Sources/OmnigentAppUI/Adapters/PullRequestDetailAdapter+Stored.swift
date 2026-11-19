import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import UniformTypeIdentifiers

/// The open PR while its host is offline, its commit activity, and description attachments.
extension PullRequestDetailAdapter {
  /// The stored PR in place of the live detail once a read found the host offline, as the
  /// web's `StoredPullRequestDetails`; `nil` while the host answers or the PR isn't stored.
  static func stored(_ panel: SessionPanelStore) -> PullRequestDetailContent? {
    guard let url = panel.openPullRequest, panel.detail.error?.isHostOffline == true,
      let pullRequest = panel.pullRequests.value?.pullRequests.first(where: { $0.url == url })
    else { return nil }
    return .stored(stored(pullRequest))
  }

  /// The stored PR's title, number, repository and state, and when the host last read them.
  static func stored(_ pullRequest: SessionPullRequest) -> PullRequestStoredViewState {
    let title = pullRequest.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let synced = pullRequest.stateCheckedAt.map { seconds in
      let date = Date(timeIntervalSince1970: seconds)
      return "Last sync time: \(date.formatted(date: .abbreviated, time: .shortened)). "
    }
    let number = "\(pullRequest.numberPrefix)\(pullRequest.number)"
    return PullRequestStoredViewState(
      url: pullRequest.url,
      title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "\(pullRequest.repository) \(number)",
      numberLabel: number, repository: pullRequest.repository,
      status: PullRequestAdapter.summary(pullRequest).status,
      providerName: pullRequest.providerName ?? "GitHub",
      hint: (synced ?? "") + "To load the PR details, please reconnect the session\u{2019}s host.")
  }

  /// The PR's commits and force pushes for the Comments feed.
  static func timeline(_ pullRequest: PullRequestDetail) -> [PullRequestTimelineRow] {
    pullRequest.timelineEvents.map { event in
      let kind: PullRequestTimelineRow.Kind =
        switch event.kind {
        case .commit: .commit
        case .forcePush(let previous): .forcePush(previousSHA: previous)
        }
      return PullRequestTimelineRow(
        id: event.id, kind: kind, author: event.author ?? "unknown",
        date: event.createdAt.flatMap { try? Date($0, strategy: .iso8601) }, sha: event.sha,
        message: event.message, url: event.url.flatMap(URL.init(string:)))
    }
  }
}

/// Uploads a description attachment the user picked: checks its type and size as the web
/// does, reads it off the main actor, and sends it through the panel store.
enum PullRequestAttachments {
  /// Uploads `file`.
  /// - Parameters:
  ///   - file: The picked image or video.
  ///   - panel: The session's panel store.
  /// - Returns: The Markdown that embeds it, or why it wasn't attached.
  static func upload(_ file: URL, to panel: SessionPanelStore) async
    -> PullRequestAttachmentOutcome
  {
    let name = file.lastPathComponent
    let contentType =
      UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    let data: Data
    do {
      data = try await read(file, name: name, contentType: contentType)
    } catch let failure as AttachmentFailure {
      return .failed(failure.message)
    } catch {
      return .failed("Couldn\u{2019}t attach \(name): \(error.localizedDescription)")
    }
    switch await panel.uploadAttachment(fileName: name, contentType: contentType, data: data) {
    case .success(let markdown): return .attached(markdown: markdown)
    case .failure(let error): return .failed("Couldn\u{2019}t attach \(name): \(error.message)")
    }
  }

  nonisolated private struct AttachmentFailure: Error {
    let message: String
  }

  /// The file's bytes, read with the access the picker granted.
  private static func read(_ file: URL, name: String, contentType: String) async throws -> Data {
    try await Task.detached {
      let scoped = file.startAccessingSecurityScopedResource()
      defer { if scoped { file.stopAccessingSecurityScopedResource() } }
      let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      if let problem = pullRequestAttachmentProblem(
        fileName: name, contentType: contentType, size: UInt64(max(size, 0)))
      {
        throw AttachmentFailure(message: problem)
      }
      return try Data(contentsOf: file)
    }.value
  }
}
