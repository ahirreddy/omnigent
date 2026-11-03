#if os(macOS)
  import AppKit
  import Foundation

  /// Captures a window through the window server, so Liquid Glass, materials and scroll edge
  /// effects draw: `cacheDisplay` leaves them out. The window sits behind the desktop, out of
  /// sight. Needs Screen Recording permission for the process that runs the export.
  enum CatalogWindowCapture {
    /// Why a capture failed.
    enum Failure: Error, CustomStringConvertible {
      case captureFailed(name: String, status: Int32, output: String)

      var description: String {
        switch self {
        case .captureFailed(let name, let status, let output):
          "screencapture exited \(status) for \(name): \(output)"
        }
      }
    }

    /// Puts `window` on screen behind the desktop, so the window server composites it.
    static func prepare(_ window: NSWindow) {
      window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
      window.orderFrontRegardless()
    }

    /// The window's pixels, without its shadow, as PNG data.
    static func capture(_ window: NSWindow, name: String) async throws -> Data {
      let file = FileManager.default.temporaryDirectory
        .appending(path: "omnigent-gallery-\(UUID().uuidString).png")
      // A temporary file; nothing to report if removing it fails.
      defer { try? FileManager.default.removeItem(at: file) }
      let process = Process()
      process.executableURL = URL(filePath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", file.path]
      let errors = Pipe()
      process.standardError = errors
      process.standardOutput = errors
      try process.run()
      while process.isRunning {
        try await Task.sleep(for: .milliseconds(20))
      }
      let data = errors.fileHandleForReading.readDataToEndOfFile()
      let output = String(bytes: data, encoding: .utf8) ?? "\(data.count) bytes of non-UTF-8 output"
      guard process.terminationStatus == 0 else {
        throw Failure.captureFailed(
          name: name, status: process.terminationStatus, output: output)
      }
      return try Data(contentsOf: file)
    }
  }
#endif
