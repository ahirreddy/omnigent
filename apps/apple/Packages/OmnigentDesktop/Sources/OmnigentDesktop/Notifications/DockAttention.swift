import AppKit
import Foundation

/// Dock badge and bounce.
public enum DockAttention {
  /// Shows `count` on the Dock icon, or clears it for zero.
  ///
  /// macOS only draws the badge while the app's notification setting allows badges, so request
  /// `.badge` authorization through `DesktopNotificationCenter`.
  /// - Parameter count: The unread total.
  public static func setBadge(_ count: Int) {
    NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
  }

  /// Bounces the Dock icon once. AppKit ignores the request while the app is active.
  public static func requestAttention() {
    // The request id is only needed to cancel early; activation cancels it anyway.
    _ = NSApplication.shared.requestUserAttention(.informationalRequest)
  }
}

/// macOS system alert sounds from `/System/Library/Sounds`.
public enum SystemSounds {
  /// The default notification sound, as in the Electron app.
  public static let defaultName = "Glass"

  /// Installed sound names without extension, sorted.
  /// - Returns: For example `["Basso", "Blow", ..., "Tink"]`.
  /// - Throws: The file system error when the directory cannot be listed.
  public static func names() throws -> [String] {
    let directory = URL(filePath: "/System/Library/Sounds", directoryHint: .isDirectory)
    return try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "aiff" }
    .map { $0.deletingPathExtension().lastPathComponent }
    .sorted()
  }

  /// Plays a system sound by name.
  /// - Parameter name: A name from `names()`.
  /// - Throws: `DesktopNotificationError.soundUnavailable` when it cannot be loaded or played.
  public static func play(_ name: String) throws(DesktopNotificationError) {
    guard let sound = NSSound(named: NSSound.Name(name)), sound.play() else {
      throw .soundUnavailable(name)
    }
  }
}
