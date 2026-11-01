public import Foundation
internal import os

/// Removing a persistent profile's storage. The host may still write to a context it is
/// releasing, so the directory is removed now and again before the next host starts.
extension Session {
  /// The file listing storage keys whose directories are removed at the next launch.
  var pendingDeletionsURL: URL {
    configuration.rootCacheURL.appending(path: "pending-profile-deletions.json")
  }

  /// The directory of a persistent profile's storage.
  public func storageDirectory(forProfileIdentifier identifier: String) -> URL {
    configuration.rootCacheURL.appending(
      path: "Profile-\(Profile.storageKey(for: identifier))", directoryHint: .isDirectory)
  }

  /// The open profile for `identifier`, if any.
  public func existingProfile(identifier: String, persistence: Profile.Persistence) -> Profile? {
    profilesByKey["\(persistence == .persistent ? "p" : "e"):\(identifier)"]
  }

  /// Closes the persistent profile `identifier` (and its views) and deletes its cookies, storage
  /// and cache from disk. The host releases the profile asynchronously and may still be writing
  /// to it, so the directory is also queued and removed before the next host starts.
  /// - Returns: Whether the directory is gone now; otherwise the next launch removes it.
  /// - Throws: `.invalidArgument` when the queue of pending deletions cannot be written.
  @discardableResult
  public func deletePersistentStorage(identifier: String) throws(WebLayerError) -> Bool {
    existingProfile(identifier: identifier, persistence: .persistent)?.close()
    let key = Profile.storageKey(for: identifier)
    var pending = try readPendingDeletions()
    if !pending.contains(key) { pending.append(key) }
    try writePendingDeletions(pending)
    do {
      try removeStorageDirectory(key: key)
      return true
    } catch {
      Logger.session.info(
        "Profile \(key, privacy: .public) is still in use; removing it at the next launch: \(error.localizedDescription, privacy: .public)"
      )
      return false
    }
  }

  /// Removes directories queued by `deletePersistentStorage` while no host runs.
  func sweepPendingDeletions() throws(WebLayerError) {
    let pending = try readPendingDeletions()
    guard !pending.isEmpty else { return }
    for key in pending {
      try removeStorageDirectory(key: key)
    }
    try writePendingDeletions([])
  }

  private func removeStorageDirectory(key: String) throws(WebLayerError) {
    let directory = configuration.rootCacheURL.appending(
      path: "Profile-\(key)", directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      throw .invalidArgument(
        "Could not delete \(directory.path): \(error.localizedDescription)")
    }
  }

  private func readPendingDeletions() throws(WebLayerError) -> [String] {
    guard FileManager.default.fileExists(atPath: pendingDeletionsURL.path) else { return [] }
    do {
      return try JSONDecoder().decode([String].self, from: Data(contentsOf: pendingDeletionsURL))
    } catch {
      throw .invalidArgument(
        "Could not read \(pendingDeletionsURL.path): \(error.localizedDescription)")
    }
  }

  private func writePendingDeletions(_ keys: [String]) throws(WebLayerError) {
    do {
      try FileManager.default.createDirectory(
        at: configuration.rootCacheURL, withIntermediateDirectories: true)
      try JSONEncoder().encode(keys).write(to: pendingDeletionsURL, options: .atomic)
    } catch {
      throw .invalidArgument(
        "Could not write \(pendingDeletionsURL.path): \(error.localizedDescription)")
    }
  }
}

extension Profile {
  /// The storage key for `identifier`; see `storageKey`.
  nonisolated static func storageKey(for identifier: String) -> String {
    SHA256Digest16.hex(identifier)
  }

  /// The views open in this profile.
  public var views: [WebView] {
    session.views.values.filter { $0.profile === self }.sorted { $0.id < $1.id }
  }
}
