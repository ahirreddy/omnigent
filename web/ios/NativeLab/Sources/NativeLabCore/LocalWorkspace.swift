import Foundation

public struct LocalWorkspace: Codable, Equatable, Sendable {
  public var version: Int = 1
  public var snapshots: [ConversationSnapshot]
  public var drafts: [String: String]

  public init(snapshots: [ConversationSnapshot], drafts: [String: String] = [:]) {
    self.snapshots = snapshots
    self.drafts = drafts
  }

  public func recoveringInterruptedReplies() -> LocalWorkspace {
    var recovered = self
    for index in recovered.snapshots.indices {
      var snapshot = recovered.snapshots[index]
      guard snapshot.session.status == .running || snapshot.messages.contains(where: \.isStreaming)
      else { continue }
      for messageIndex in snapshot.messages.indices
      where snapshot.messages[messageIndex].isStreaming {
        let partial = snapshot.messages[messageIndex].text
        snapshot.messages[messageIndex].text =
          partial.isEmpty
          ? "Sample reply interrupted when the app closed."
          : partial + "\n\nSample reply interrupted when the app closed."
        snapshot.messages[messageIndex].isStreaming = false
      }
      snapshot.session.status = snapshot.pendingDecisions.isEmpty ? .idle : .needsResponse
      snapshot.session.preview = snapshot.messages.last?.text ?? snapshot.session.preview
      snapshot.revision += 1
      recovered.snapshots[index] = snapshot
    }
    return recovered
  }
}

public struct LocalWorkspaceStore: Sendable {
  public let url: URL

  public init(url: URL) { self.url = url }

  public func load() throws -> LocalWorkspace? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let workspace = try JSONDecoder().decode(LocalWorkspace.self, from: Data(contentsOf: url))
    guard workspace.version == 1,
      Set(workspace.snapshots.map(\.id)).count == workspace.snapshots.count
    else { throw CocoaError(.fileReadCorruptFile) }
    return workspace.recoveringInterruptedReplies()
  }

  public func save(_ workspace: LocalWorkspace) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let data = try JSONEncoder().encode(workspace)
    #if os(iOS)
      try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    #else
      try data.write(to: url, options: .atomic)
    #endif
  }
}
