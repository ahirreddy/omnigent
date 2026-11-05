public import Foundation

/// This Mac's identity as a host: the CLI's `config.yaml`, which holds its host id.
extension LocalServerManager {
  /// The CLI's config file: `$OMNIGENT_CONFIG_HOME/config.yaml`, or `~/.omnigent/config.yaml`
  /// (`omnigent/host/identity.py`).
  public var cliConfigFile: URL {
    let home = dependencies.homeDirectory
    let raw = dependencies.environment["OMNIGENT_CONFIG_HOME"]?
      .trimmingCharacters(in: .whitespaces)
    let directory: URL
    if let raw, !raw.isEmpty {
      directory =
        raw.hasPrefix("~")
        ? home.appending(path: String(raw.dropFirst()).trimmingPrefix("/"))
        : URL(filePath: raw, directoryHint: .isDirectory)
    } else {
      directory = home.appending(path: ".omnigent", directoryHint: .isDirectory)
    }
    return directory.appending(path: "config.yaml")
  }

  /// The CLI config's text, which names this Mac's host id once the CLI generated one.
  /// - Returns: The text, or `nil` when this edition cannot run the CLI or the file does not
  ///   exist yet.
  /// - Throws: A read error other than the file not existing.
  public func cliConfigText() throws -> String? {
    guard capability.isAvailable else { return nil }
    do {
      return try String(contentsOf: cliConfigFile, encoding: .utf8)
    } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
      return nil
    }
  }
}
