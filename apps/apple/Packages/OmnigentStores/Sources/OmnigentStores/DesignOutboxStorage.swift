public import Foundation

/// Who a design request belongs to: its server and the account signed in when it was made.
nonisolated public struct DesignOutboxOwner: Hashable, Sendable, Codable {
  /// The server's API root.
  public var server: String
  /// The account scope (server plus user), as the core names it.
  public var account: String

  /// Creates an owner.
  public init(server: String, account: String) {
    self.server = server
    self.account = account
  }
}

/// The outbox's unsent design requests on disk (web `designOutboxStorage.ts`), so quitting
/// doesn't lose them: a JSON index beside each request's files, under Application Support.
/// Windows share it; a request a window holds is that window's until the window goes.
public final class DesignOutboxStorage {
  /// How old a saved request may be when a window restores: older ones, anyone's, go then.
  public static let lifetime: TimeInterval = 24 * 60 * 60

  /// The app's, under `Application Support/<bundle id>/design-outbox`, or `nil` when
  /// Application Support cannot be located.
  public static let shared: DesignOutboxStorage? = {
    do {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      let folder = support.appending(path: Bundle.main.bundleIdentifier ?? "Omnigent")
      return DesignOutboxStorage(folder: folder.appending(path: "design-outbox"))
    } catch {
      NSLog("Design requests are not kept across launches: %@", error.localizedDescription)
      return nil
    }
  }()

  /// The last failure to read or write, until the next success.
  public private(set) var lastError: String?

  private let folder: URL
  private let now: () -> Date
  /// The index as last read or written; read from disk on first use.
  private var records: [UUID: DesignOutboxRecord] = [:]
  private var isLoaded = false
  /// The window holding each request it saved or restored, while that window lives.
  private var holders: [UUID: WeakHolder] = [:]

  private final class WeakHolder {
    weak var outbox: DesignRequestOutbox?
    init(_ outbox: DesignRequestOutbox) { self.outbox = outbox }
  }

  /// Storage in `folder`.
  /// - Parameters:
  ///   - folder: Where the index and files go.
  ///   - now: The current time, for a request's age.
  public init(folder: URL, now: @escaping () -> Date = Date.init) {
    self.folder = folder
    self.now = now
  }

  private var indexURL: URL { folder.appending(path: "index.json") }

  private func fileURL(_ id: UUID, _ index: Int) -> URL {
    folder.appending(path: id.uuidString).appending(path: "\(index)")
  }

  /// Keeps `request` (not sent) as `holder`'s; its files are written once.
  func save(_ request: DesignOutboxRequest, owner: DesignOutboxOwner, holder: DesignRequestOutbox) {
    var all = loaded()
    let savedAt = all[request.id]?.savedAt ?? request.madeAt
    if all[request.id] == nil {
      do {
        try FileManager.default.createDirectory(
          at: folder.appending(path: request.id.uuidString), withIntermediateDirectories: true)
        for (index, file) in request.files.enumerated() {
          try file.data.write(to: fileURL(request.id, index), options: .atomic)
        }
      } catch {
        lastError = "A design request could not be saved: \(error.localizedDescription)"
        return
      }
    }
    all[request.id] = DesignOutboxRecord(request, owner: owner, savedAt: savedAt)
    holders[request.id] = WeakHolder(holder)
    write(all)
  }

  /// Forgets a request that was sent or removed.
  func delete(_ id: UUID) {
    var all = loaded()
    holders[id] = nil
    guard all.removeValue(forKey: id) != nil else { return }
    removeFiles(id)
    write(all)
  }

  /// The requests of `owner` that no live window holds, taken by `holder`, oldest first. Those
  /// past ``lifetime``, anyone's, and other accounts' on the same server are deleted.
  func adopt(owner: DesignOutboxOwner, holder: DesignRequestOutbox)
    -> [(record: DesignOutboxRecord, files: [DesignOutboxRequest.File])]
  {
    var all = loaded()
    let expired = now().addingTimeInterval(-Self.lifetime)
    var adopted: [(record: DesignOutboxRecord, files: [DesignOutboxRequest.File])] = []
    for record in all.values.sorted(by: { $0.savedAt < $1.savedAt }) {
      let held = holders[record.id]?.outbox
      let othersHere = record.owner.server == owner.server && record.owner != owner
      if held == nil, record.savedAt < expired || othersHere {
        all[record.id] = nil
        removeFiles(record.id)
        continue
      }
      guard record.owner == owner, held == nil else { continue }
      do {
        let files = try record.files.indices.map { index in
          DesignOutboxRequest.File(
            name: record.files[index].name, mediaType: record.files[index].mediaType,
            data: try Data(contentsOf: fileURL(record.id, index)))
        }
        adopted.append((record, files))
        holders[record.id] = WeakHolder(holder)
      } catch {
        lastError = "A saved design request could not be read: \(error.localizedDescription)"
        all[record.id] = nil
        removeFiles(record.id)
      }
    }
    write(all)
    return adopted
  }

  private func loaded() -> [UUID: DesignOutboxRecord] {
    if isLoaded { return records }
    var read: [UUID: DesignOutboxRecord] = [:]
    if FileManager.default.fileExists(atPath: indexURL.path()) {
      do {
        let list = try JSONDecoder().decode(
          [DesignOutboxRecord].self, from: Data(contentsOf: indexURL))
        read = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      } catch {
        lastError = "Saved design requests could not be read: \(error.localizedDescription)"
      }
    }
    records = read
    isLoaded = true
    return read
  }

  private func write(_ all: [UUID: DesignOutboxRecord]) {
    records = all
    isLoaded = true
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let list = all.values.sorted { $0.savedAt < $1.savedAt }
      try JSONEncoder().encode(list).write(to: indexURL, options: .atomic)
      lastError = nil
    } catch {
      lastError = "Design requests could not be saved: \(error.localizedDescription)"
    }
  }

  private func removeFiles(_ id: UUID) {
    let requestFolder = folder.appending(path: id.uuidString)
    guard FileManager.default.fileExists(atPath: requestFolder.path()) else { return }
    do {
      try FileManager.default.removeItem(at: requestFolder)
    } catch {
      lastError = "A design request's files could not be removed: \(error.localizedDescription)"
    }
  }
}

/// One saved request in the index.
struct DesignOutboxRecord: Codable, Hashable {
  struct File: Codable, Hashable {
    var name: String
    var mediaType: String
  }

  enum Status: String, Codable {
    case waiting, sending, failed
  }

  var id: UUID
  var sessionID: String
  var owner: DesignOutboxOwner
  var tool: DesignOutboxRequest.Tool
  var label: String
  var text: String
  var files: [File]
  var status: Status
  var error: String?
  var canRetry: Bool
  /// When it was made: later saves keep it, so its age runs from then.
  var savedAt: Date
}

extension DesignOutboxRecord {
  init(_ request: DesignOutboxRequest, owner: DesignOutboxOwner, savedAt: Date) {
    id = request.id
    sessionID = request.sessionID
    self.owner = owner
    tool = request.tool
    label = request.label
    text = request.text
    files = request.files.map { File(name: $0.name, mediaType: $0.mediaType) }
    switch request.status {
    case .waiting: (status, error, canRetry) = (.waiting, nil, true)
    case .sending: (status, error, canRetry) = (.sending, nil, true)
    case .failed(let message, let retry): (status, error, canRetry) = (.failed, message, retry)
    }
    self.savedAt = savedAt
  }
}
