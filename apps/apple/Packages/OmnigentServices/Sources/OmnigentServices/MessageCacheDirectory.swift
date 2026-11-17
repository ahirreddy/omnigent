public import Foundation
import OSLog

/// Where the core keeps this device's saved copy of sessions (`HostConfig.cacheDirectory`): a
/// folder in the app's Caches. On iOS its files are protected while the device is locked; files
/// the core creates in it inherit that.
public enum MessageCacheDirectory {
  /// The folder's name inside the app's own Caches folder.
  static let name = "MessageCache"

  /// The folder, created when missing. A folder that cannot be created or protected is logged and
  /// still returned: the core then reports each failed write.
  /// - Parameters:
  ///   - fileManager: The file manager.
  ///   - bundleIdentifier: The app's bundle id, which keeps the Mac's shared Caches apart.
  /// - Returns: The folder, or `nil` when the system has no Caches folder for the app.
  public static func prepared(
    fileManager: FileManager = .default,
    bundleIdentifier: String? = Bundle.main.bundleIdentifier
  ) -> URL? {
    guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      servicesLogger.error("The system has no Caches folder; sessions are not saved offline")
      return nil
    }
    let folder = caches.appending(path: bundleIdentifier ?? "ai.omnigent.app")
      .appending(path: name, directoryHint: .isDirectory)
    do {
      try fileManager.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: protection)
      // A folder made before protection was set gets it now.
      if !protection.isEmpty {
        try fileManager.setAttributes(protection, ofItemAtPath: folder.path(percentEncoded: false))
      }
    } catch {
      servicesLogger.error(
        "Could not prepare the saved-sessions folder: \(error.localizedDescription, privacy: .public)"
      )
    }
    return folder
  }

  /// Unreadable while the device is locked, except by a file already open; new files can still
  /// be written then, so a session that streams in the background keeps saving.
  private static var protection: [FileAttributeKey: Any] {
    #if os(iOS)
      [.protectionKey: FileProtectionType.completeUnlessOpen]
    #else
      [:]
    #endif
  }
}
