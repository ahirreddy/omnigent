import Combine
import Foundation

public struct AttachmentDraftKey: Hashable, Sendable {
  public let scope: String
  public let sessionID: String
  public init(scope: String, sessionID: String) {
    self.scope = scope
    self.sessionID = sessionID
  }
}

public enum AttachmentUploadState: Equatable, Sendable {
  case staged
  case uploading(Double)
  case uploaded(UploadedAttachment)
  case failed(String)
  case uncertain(String)
}

public struct AttachmentDraftItem: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let file: AttachmentUploadFile
  public internal(set) var state: AttachmentUploadState
}

public struct AttachmentDraft: Equatable, Sendable {
  public internal(set) var items: [AttachmentDraftItem] = []
  public internal(set) var selectionError: String?
  public var hasAttachments: Bool { !items.isEmpty }
}

public struct AttachmentSubmission: Equatable, Sendable {
  public let id: UUID
  public let key: AttachmentDraftKey
  public let attachments: [UploadedAttachment]
  let itemIDs: Set<UUID>
}

@MainActor
public final class AttachmentDraftStore: ObservableObject {
  public typealias Uploader =
    @Sendable (
      AttachmentUploadFile, String, @escaping @Sendable (Double) -> Void
    ) async throws -> UploadedAttachment

  @Published public private(set) var drafts: [AttachmentDraftKey: AttachmentDraft] = [:]
  @Published private var submissions: [AttachmentDraftKey: AttachmentSubmission] = [:]
  @Published private var uncertainSubmissions: Set<AttachmentDraftKey> = []
  private var tasks: [UUID: Task<UploadedAttachment, Error>] = [:]
  private var attempts: [UUID: UUID] = [:]

  public init() {}
  deinit { for task in tasks.values { task.cancel() } }

  public func draft(for key: AttachmentDraftKey) -> AttachmentDraft {
    drafts[key] ?? AttachmentDraft()
  }

  @discardableResult
  public func add(_ file: AttachmentUploadFile, to key: AttachmentDraftKey) throws -> UUID {
    let draft = draft(for: key)
    let bytes = draft.items.reduce(0) { $0 + $1.file.data.count }
    let total = drafts.values.flatMap(\.items).reduce(0) { $0 + $1.file.data.count }
    guard draft.items.count < AttachmentUploadPolicy.maximumFilesPerDraft,
      bytes + file.data.count <= AttachmentUploadPolicy.maximumDraftBytes,
      total + file.data.count <= AttachmentUploadPolicy.maximumStoredBytes
    else { throw AttachmentUploadError.draftLimit }
    let id = UUID()
    drafts[key, default: AttachmentDraft()].items.append(
      AttachmentDraftItem(id: id, file: file, state: .staged))
    return id
  }

  public func recordSelectionError(_ message: String?, in key: AttachmentDraftKey) {
    drafts[key, default: AttachmentDraft()].selectionError = message
  }

  public func upload(_ id: UUID, in key: AttachmentDraftKey, using client: LocalServerSessionClient)
    async
  {
    await upload(id, in: key) { file, sessionID, progress in
      try await client.uploadAttachment(file, sessionID: sessionID, progress: progress)
    }
  }

  public func upload(_ id: UUID, in key: AttachmentDraftKey, using uploader: @escaping Uploader)
    async
  {
    guard !isLocked(id, in: key), tasks[id] == nil,
      let item = draft(for: key).items.first(where: { $0.id == id })
    else { return }
    switch item.state {
    case .staged, .failed: break
    default: return
    }
    setState(.uploading(0), id: id, key: key)
    let attempt = UUID()
    attempts[id] = attempt
    let task = Task { [weak self] in
      try Task.checkCancellation()
      return try await uploader(item.file, key.sessionID) { [weak self] progress in
        Task { @MainActor in
          guard let self, self.attempts[id] == attempt,
            let current = self.draft(for: key).items.first(where: { $0.id == id }),
            case .uploading(let previous) = current.state
          else { return }
          self.setState(.uploading(max(previous, min(1, max(0, progress)))), id: id, key: key)
        }
      }
    }
    tasks[id] = task
    defer {
      tasks[id] = nil
      attempts[id] = nil
    }
    do {
      let uploaded = try await task.value
      guard uploaded.sessionID == key.sessionID else { throw AttachmentUploadError.uploadUncertain }
      setState(.uploaded(uploaded), id: id, key: key)
    } catch {
      if error as? AttachmentUploadError == .uploadUncertain
        || error as? LocalServerClientError == .deliveryUncertain
      {
        setState(
          .uncertain(AttachmentUploadError.uploadUncertain.localizedDescription), id: id, key: key)
      } else {
        setState(.failed(error.localizedDescription), id: id, key: key)
      }
    }
  }

  public func cancelUpload(_ id: UUID, in key: AttachmentDraftKey) {
    guard draft(for: key).items.contains(where: { $0.id == id }) else { return }
    tasks[id]?.cancel()
  }

  public func cancelUploads(in key: AttachmentDraftKey) {
    for item in draft(for: key).items { cancelUpload(item.id, in: key) }
  }

  public func remove(_ id: UUID, from key: AttachmentDraftKey) {
    guard !isLocked(id, in: key), tasks[id] == nil else { return }
    drafts[key]?.items.removeAll { $0.id == id }
  }

  public func isLocked(_ id: UUID, in key: AttachmentDraftKey) -> Bool {
    submissions[key]?.itemIDs.contains(id) == true || uncertainSubmissions.contains(key)
  }

  public func canSubmit(in key: AttachmentDraftKey) -> Bool {
    submissions[key] == nil && !uncertainSubmissions.contains(key)
      && draft(for: key).items.allSatisfy {
        if case .uploaded = $0.state { return true }
        return false
      }
  }

  public func beginSubmission(in key: AttachmentDraftKey) throws -> AttachmentSubmission {
    guard canSubmit(in: key) else { throw AttachmentUploadError.notReady }
    let items = draft(for: key).items
    let batch = AttachmentSubmission(
      id: UUID(), key: key,
      attachments: items.compactMap {
        if case .uploaded(let ref) = $0.state { return ref }
        return nil
      },
      itemIDs: Set(items.map(\.id)))
    submissions[key] = batch
    return batch
  }

  public func finishSubmission(_ batch: AttachmentSubmission, outcome: SubmissionLedger.Outcome) {
    guard submissions[batch.key] == batch else { return }
    submissions[batch.key] = nil
    switch outcome {
    case .accepted: drafts[batch.key]?.items.removeAll { batch.itemIDs.contains($0.id) }
    case .rejected: break
    case .uncertain: uncertainSubmissions.insert(batch.key)
    }
  }

  public func acknowledgeUncertainty(in key: AttachmentDraftKey) {
    uncertainSubmissions.remove(key)
  }

  private func setState(_ state: AttachmentUploadState, id: UUID, key: AttachmentDraftKey) {
    guard let index = drafts[key]?.items.firstIndex(where: { $0.id == id }) else { return }
    drafts[key]?.items[index].state = state
  }
}
