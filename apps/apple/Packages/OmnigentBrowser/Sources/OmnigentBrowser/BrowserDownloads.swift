public import Foundation
public import Observation

/// Where a download stands.
nonisolated public enum BrowserDownloadState: Sendable, Hashable {
  /// Receiving data.
  case inProgress
  /// Paused.
  case paused
  /// Finished; the file is at the destination.
  case complete
  /// Cancelled.
  case cancelled
  /// Failed, with the engine's reason.
  case failed(String)

  /// Whether the download stopped for good.
  public var isFinal: Bool {
    switch self {
    case .inProgress, .paused: false
    case .complete, .cancelled, .failed: true
    }
  }
}

/// One download from either engine.
@Observable
public final class BrowserDownload: Identifiable {
  /// Identity.
  public let id = UUID()
  /// What is downloaded.
  public let url: URL?
  /// The file name.
  public let suggestedName: String
  /// Where the file goes.
  public let destination: URL
  /// The engine downloading it.
  public let engine: BrowserEngineKind
  /// Bytes received.
  public package(set) var receivedBytes: Int64 = 0
  /// The size, when known.
  public package(set) var totalBytes: Int64?
  /// Progress state.
  public package(set) var state = BrowserDownloadState.inProgress
  @ObservationIgnored private let cancelAction: () throws(BrowserError) -> Void

  /// Creates a download; `cancel` asks the engine to stop it.
  package init(
    url: URL?, suggestedName: String, destination: URL, engine: BrowserEngineKind,
    totalBytes: Int64?, cancel: @escaping () throws(BrowserError) -> Void
  ) {
    self.url = url
    self.suggestedName = suggestedName
    self.destination = destination
    self.engine = engine
    self.totalBytes = totalBytes
    cancelAction = cancel
  }

  /// Progress in `0...1`, when the size is known.
  public var fractionCompleted: Double? {
    if state == .complete { return 1 }
    guard let totalBytes, totalBytes > 0 else { return nil }
    return min(1, Double(receivedBytes) / Double(totalBytes))
  }

  /// Stops the download.
  public func cancel() throws(BrowserError) {
    guard !state.isFinal else { throw .downloadFailed("The download already stopped.") }
    try cancelAction()
  }
}

/// Every download in the app, newest first. Shared by every tab and both engines.
@Observable
public final class BrowserDownloadCenter {
  /// The app-wide list.
  public static let shared = BrowserDownloadCenter()

  /// The downloads.
  public private(set) var items: [BrowserDownload] = []

  /// Creates an empty list; tests make their own.
  public init() {}

  /// Adds a download at the top.
  public func add(_ download: BrowserDownload) {
    guard !items.contains(where: { $0 === download }) else { return }
    items.insert(download, at: 0)
  }

  /// Removes finished downloads. Files stay on disk.
  public func clearFinished() {
    items.removeAll { $0.state.isFinal }
  }

  /// Whether anything is still downloading.
  public var hasActiveDownloads: Bool {
    items.contains { !$0.state.isFinal }
  }
}

/// Download preferences: the save folder and whether to ask each time. Persisted in
/// `UserDefaults`.
@Observable
public final class BrowserDownloadSettings {
  /// Key for the folder path.
  public static let directoryKey = "ai.omnigent.browser.downloads.directory"
  /// Key for the ask flag.
  public static let askKey = "ai.omnigent.browser.downloads.ask"

  @ObservationIgnored private let defaults: UserDefaults

  /// Where downloads go unless the user is asked. Defaults to ~/Downloads.
  public var directory: URL {
    didSet { defaults.set(directory.path, forKey: Self.directoryKey) }
  }

  /// Whether to ask for a location for each download.
  public var askBeforeDownload: Bool {
    didSet { defaults.set(askBeforeDownload, forKey: Self.askKey) }
  }

  /// Reads the settings from `defaults`.
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let path = defaults.string(forKey: Self.directoryKey), !path.isEmpty {
      directory = URL(fileURLWithPath: path, isDirectory: true)
    } else {
      directory = URL.downloadsDirectory
    }
    askBeforeDownload = defaults.bool(forKey: Self.askKey)
  }

  /// A destination in `directory` that does not exist yet: "name.ext", then "name 2.ext", ...
  public func uniqueDestination(for suggestedName: String, fileManager: FileManager = .default)
    -> URL
  {
    let cleaned = Self.safeFileName(suggestedName)
    let file = URL(fileURLWithPath: cleaned)
    let base = file.deletingPathExtension().lastPathComponent
    let ext = file.pathExtension
    var candidate = directory.appending(path: cleaned, directoryHint: .notDirectory)
    var counter = 2
    while fileManager.fileExists(atPath: candidate.path) {
      let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
      candidate = directory.appending(path: name, directoryHint: .notDirectory)
      counter += 1
    }
    return candidate
  }

  /// A name with no path separators and no leading dots, so a server cannot pick the folder.
  public static func safeFileName(_ name: String) -> String {
    let lastComponent = name.split(separator: "/").last.map(String.init) ?? ""
    var cleaned = lastComponent.replacingOccurrences(of: ":", with: "-")
    while cleaned.hasPrefix(".") {
      cleaned.removeFirst()
    }
    return cleaned.isEmpty ? "download" : cleaned
  }
}
