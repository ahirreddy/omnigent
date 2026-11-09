// Owns one libghostty surface driven by a remote `TerminalConnection`.
//
// Surface creation, sizing and the clipboard/action plumbing follow Ghostty's macOS app
// (`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` and `SurfaceView_UIKit.swift`),
// MIT License, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. The manual I/O mode
// (`GHOSTTY_SURFACE_IO_MANUAL_MIRROR`, `io_write_cb`, `ghostty_surface_process_output`) is from the
// manaflow-ai/ghostty fork (MIT). See THIRD_PARTY_NOTICES.md.

import CoreGraphics
public import Foundation
public import Observation
import OmnigentGhosttyKit

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Receives the bytes libghostty encodes for the remote side (keys, IME commits, paste, mouse
/// reports) on libghostty's I/O thread and hands them to the main actor.
private nonisolated final class SurfaceInputSink: Sendable {
  let continuation: AsyncStream<[UInt8]>.Continuation

  init(continuation: AsyncStream<[UInt8]>.Continuation) {
    self.continuation = continuation
  }
}

/// libghostty's `io_write_cb`: runs on the surface's I/O thread.
private nonisolated func ghosttyIOWrite(
  _ userdata: UnsafeMutableRawPointer?, _ data: UnsafePointer<CChar>?, _ length: UInt
) {
  guard let userdata = unsafe userdata, let data = unsafe data, length > 0 else { return }
  let sink = unsafe Unmanaged<SurfaceInputSink>.fromOpaque(userdata).takeUnretainedValue()
  let buffer = unsafe UnsafeRawBufferPointer(start: data, count: Int(length))
  sink.continuation.yield(unsafe Array(buffer))
}

/// The state of the find bar.
public struct TerminalSearch: Hashable, Sendable {
  /// The search text.
  public var needle: String
  /// Matches, when Ghostty has counted them.
  public var total: Int?
  /// The selected match, 0-based, when one is selected.
  public var selected: Int?
}

/// A clipboard write the remote side asked for, waiting for the user's consent.
public struct PendingClipboardWrite: Hashable, Sendable, Identifiable {
  /// A token for this request.
  public let id: UUID
  /// The text.
  public let text: String
}

/// One terminal surface: a libghostty surface in manual I/O mode, the platform view it renders
/// into, and the pumps that connect it to a ``TerminalConnection``.
///
/// Output bytes from the connection are parsed and rendered by Ghostty; every byte Ghostty
/// encodes for the program (keystrokes in whatever keyboard protocol the program enabled, IME
/// commits, bracketed paste, SGR mouse reports) goes back through ``TerminalConnection/send(_:)``.
/// Grid changes go through ``TerminalConnection/resize(_:)``. The surface runs in
/// `MANUAL_MIRROR` mode, so Ghostty never answers terminal queries itself: tmux, the pane's real
/// terminal, already answers them (see DESIGN.md).
///
/// Keep the controller alive across view changes (for example a Chat/Terminal switch): the
/// surface holds the screen and scrollback, and a new controller starts blank.
@MainActor
@Observable
@safe
public final class TerminalSurfaceController {
  /// The connection this surface renders.
  public let connection: any TerminalConnection
  /// The connection's state.
  public internal(set) var state: TerminalConnectionState
  /// The title the program set (OSC 0/2), if any.
  public internal(set) var title: String?
  /// The grid size last reported to the connection.
  public internal(set) var gridSize: TerminalGridSize?
  /// The find bar, when open.
  public internal(set) var search: TerminalSearch?
  /// A remote clipboard write awaiting consent.
  public internal(set) var pendingClipboard: PendingClipboardWrite?
  /// The last renderer error. Shown in the view; never dropped.
  public internal(set) var lastError: String?

  @ObservationIgnored let runtime: GhosttyRuntime
  @ObservationIgnored private(set) var surface: ghostty_surface_t?
  @ObservationIgnored private let sink: SurfaceInputSink
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  #if os(macOS)
    /// The view the surface renders into.
    @ObservationIgnored let view: TerminalSurfaceNSView
  #else
    /// The view the surface renders into.
    @ObservationIgnored let view: TerminalSurfaceUIView
  #endif

  /// A surface for `connection`. Starts the connection.
  ///
  /// - Throws: ``GhosttyError`` when libghostty cannot start or create the surface.
  public convenience init(
    connection: any TerminalConnection, runtime: GhosttyRuntime? = nil
  ) throws(GhosttyError) {
    try unsafe self.init(connection: connection, runtime: runtime) {
      unsafe ghostty_surface_new($0, $1)
    }
  }

  init(
    connection: any TerminalConnection, runtime: GhosttyRuntime?,
    newSurface: (ghostty_app_t?, UnsafePointer<ghostty_surface_config_s>?) -> ghostty_surface_t?
  ) throws(GhosttyError) {
    let resolved: GhosttyRuntime
    if let runtime {
      resolved = runtime
    } else {
      resolved = try Self.sharedRuntime()
    }
    let runtime = resolved
    self.connection = connection
    self.runtime = runtime
    self.state = connection.state
    let (input, inputContinuation) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .unbounded)
    sink = SurfaceInputSink(continuation: inputContinuation)
    #if os(macOS)
      view = TerminalSurfaceNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    #else
      view = TerminalSurfaceUIView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    #endif
    unsafe try createSurface(newSurface)
    view.controller = self
    runtime.register(self)
    startPumps(input: input)
    connection.start()
  }

  isolated deinit {
    for task in tasks { task.cancel() }
    sink.continuation.finish()
    runtime.unregister(self)
    view.stopRendering()
    view.controller = nil
    if let surface = unsafe surface {
      unsafe ghostty_surface_free(surface)
    }
  }

  private static func sharedRuntime() throws(GhosttyError) -> GhosttyRuntime {
    try GhosttyRuntime.shared()
  }

  private func createSurface(
    _ newSurface: (ghostty_app_t?, UnsafePointer<ghostty_surface_config_s>?) -> ghostty_surface_t?
  ) throws(GhosttyError) {
    var config = unsafe ghostty_surface_config_new()
    #if os(macOS)
      unsafe config.platform_tag = GHOSTTY_PLATFORM_MACOS
      unsafe config.platform.macos.nsview = unsafe Unmanaged.passUnretained(view).toOpaque()
      unsafe config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
    #else
      unsafe config.platform_tag = GHOSTTY_PLATFORM_IOS
      unsafe config.platform.ios.uiview = unsafe Unmanaged.passUnretained(view).toOpaque()
      unsafe config.scale_factor = Double(
        view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : 3)
    #endif
    unsafe config.userdata = unsafe Unmanaged.passUnretained(self).toOpaque()
    unsafe config.font_size = 0
    unsafe config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
    unsafe config.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
    unsafe config.io_write_cb = unsafe ghosttyIOWrite
    unsafe config.io_write_userdata = unsafe Unmanaged.passUnretained(sink).toOpaque()
    guard let surface = unsafe newSurface(runtime.app, &config) else {
      throw .surfaceCreationFailed
    }
    unsafe self.surface = surface
    unsafe ghostty_surface_set_color_scheme(surface, runtime.appearance.colorScheme.ghostty)
  }

  private func startPumps(input: AsyncStream<[UInt8]>) {
    let output = connection.output
    let states = connection.states
    tasks.append(
      Task { [weak self] in
        for await item in output {
          guard let self else { return }
          self.render(item)
        }
      })
    tasks.append(
      Task { [weak self] in
        for await state in states {
          guard let self else { return }
          self.state = state
        }
      })
    tasks.append(
      Task { [weak self] in
        for await bytes in input {
          guard let self else { return }
          self.connection.send(bytes)
        }
      })
  }

  func render(_ item: TerminalOutput) {
    switch item {
    case .bytes(let bytes):
      feed(bytes)
    case .resetScreen:
      // RIS: drop the old screen, scrollback and modes. The next bytes are the server's seed of
      // the current screen.
      feed([0x1B, UInt8(ascii: "c")])
    case .clipboardWrite(let text):
      remoteCopied(text)
    }
  }

  /// Parses and renders remote output.
  func feed(_ bytes: [UInt8]) {
    guard let surface = unsafe surface, !bytes.isEmpty else { return }
    bytes.withUnsafeBufferPointer { buffer in
      unsafe buffer.withMemoryRebound(to: CChar.self) { chars in
        unsafe runtime.parse(surface, chars)
      }
    }
    view.requestRender()
  }

  /// Renders one frame now. iOS only: the view's display link calls this when Ghostty asked
  /// for a frame (`GHOSTTY_ACTION_RENDER`).
  func renderNow() {
    guard let surface = unsafe surface else { return }
    unsafe ghostty_surface_render_now(surface)
  }

  // MARK: Size, focus and appearance

  /// The view's size changed: `points` in view coordinates at `scale` pixels per point.
  func resize(points: CGSize, scale: CGFloat) {
    guard let surface = unsafe surface, let width = Self.pixels(points.width, scale),
      let height = Self.pixels(points.height, scale)
    else { return }
    unsafe ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
    unsafe ghostty_surface_set_size(surface, width, height)
    let size = unsafe ghostty_surface_size(surface)
    guard let grid = TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows)),
      grid != gridSize
    else { return }
    gridSize = grid
    connection.resize(grid)
    view.requestRender()
  }

  /// `points` at `scale` in whole pixels; `nil` for an empty or non-finite size, which
  /// `UInt32(_:)` would trap on.
  static func pixels(_ points: CGFloat, _ scale: CGFloat) -> UInt32? {
    let pixels = (points * scale).rounded()
    guard pixels.isFinite, pixels > 0 else { return nil }
    return pixels < CGFloat(UInt32.max) ? UInt32(pixels) : UInt32.max
  }

  /// The view gained or lost keyboard focus.
  func setFocused(_ focused: Bool) {
    guard let surface = unsafe surface else { return }
    unsafe ghostty_surface_set_focus(surface, focused)
    if focused { connection.foreground() }
  }

  func apply(config: ghostty_config_t, colorScheme: TerminalColorScheme) {
    guard let surface = unsafe surface else { return }
    unsafe ghostty_surface_update_config(surface, config)
    unsafe ghostty_surface_set_color_scheme(surface, colorScheme.ghostty)
  }
}
