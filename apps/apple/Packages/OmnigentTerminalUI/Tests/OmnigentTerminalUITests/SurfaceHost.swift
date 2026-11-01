import CoreImage
import Foundation
import IOSurface

@testable import OmnigentTerminalUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Hosts a surface view in a real window so libghostty sizes and renders it, and saves the
/// rendered frame (the IOSurface libghostty presents) as a PNG.
@MainActor
struct SurfaceHost {
  enum HostError: Error, CustomStringConvertible {
    case noFrame
    case encodingFailed

    var description: String {
      switch self {
      case .noFrame: "libghostty has not presented a frame (no IOSurface on the layer)."
      case .encodingFailed: "The frame could not be encoded as PNG."
      }
    }
  }

  let controller: TerminalSurfaceController
  #if os(macOS)
    let window: NSWindow
  #else
    /// A plain container: the test runner has no window scene, and libghostty's renderer draws
    /// into its IOSurface layer without one.
    let window: UIView
  #endif

  /// Where snapshots go: `OMNIGENT_TERMINAL_SNAPSHOT_DIR`, else `/private/tmp/claude-502`.
  static var outputDirectory: URL {
    URL(
      filePath: ProcessInfo.processInfo.environment["OMNIGENT_TERMINAL_SNAPSHOT_DIR"]
        ?? "/private/tmp/claude-502", directoryHint: .isDirectory)
  }

  init(controller: TerminalSurfaceController, width: CGFloat, height: CGFloat) throws {
    self.controller = controller
    let frame = CGRect(x: 0, y: 0, width: width, height: height)
    #if os(macOS)
      _ = NSApplication.shared
      window = NSWindow(
        contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = controller.view
      controller.view.frame = frame
      window.makeKeyAndOrderFront(nil)
      window.makeFirstResponder(controller.view)
    #else
      window = UIView(frame: frame)
      window.addSubview(controller.view)
      controller.view.frame = frame
      controller.view.setNeedsLayout()
      controller.view.layoutIfNeeded()
    #endif
  }

  /// Writes the last presented frame to `<outputDirectory>/term-<platform>-<name>.png`.
  func snapshot(named name: String) throws {
    #if os(macOS)
      let platform = "mac"
    #else
      let platform = "ios-unit"
    #endif
    guard let surface = frameSurface() else { throw HostError.noFrame }
    let image = CIImage(ioSurface: surface)
    let context = CIContext()
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let data = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: space)
    else { throw HostError.encodingFailed }
    try FileManager.default.createDirectory(
      at: Self.outputDirectory, withIntermediateDirectories: true)
    try data.write(to: Self.outputDirectory.appending(path: "term-\(platform)-\(name).png"))
  }

  private func frameSurface() -> IOSurface? {
    #if os(macOS)
      let layers = [controller.view.layer].compactMap(\.self)
    #else
      let layers = controller.view.layer.sublayers ?? []
    #endif
    for layer in layers {
      if let surface = layer.contents as? IOSurface {
        return surface
      }
    }
    return nil
  }
}
