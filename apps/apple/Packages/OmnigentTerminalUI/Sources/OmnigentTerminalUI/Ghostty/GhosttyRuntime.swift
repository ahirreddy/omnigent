// The libghostty app runtime: one `ghostty_app_t` per process plus its C callbacks.
//
// Adapted from Ghostty's macOS app (`macos/Sources/Ghostty/Ghostty.App.swift`), MIT License,
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. See THIRD_PARTY_NOTICES.md.

import Foundation
import OSLog
import OmnigentGhosttyKit

/// Why libghostty could not start or create a surface.
public enum GhosttyError: Error, Hashable, Sendable, CustomStringConvertible {
  /// `ghostty_init` failed with this code.
  case initFailed(code: Int32)
  /// `ghostty_app_new` returned NULL.
  case appCreationFailed
  /// `ghostty_surface_new` returned NULL.
  case surfaceCreationFailed
  /// The generated configuration has errors. Each is Ghostty's message.
  case invalidConfiguration([String])

  /// A readable description.
  public var description: String {
    switch self {
    case .initFailed(let code): "The terminal renderer failed to start (code \(code))."
    case .appCreationFailed: "The terminal renderer could not create its runtime."
    case .surfaceCreationFailed: "The terminal renderer could not create a terminal surface."
    case .invalidConfiguration(let messages):
      "The terminal configuration is invalid: " + messages.joined(separator: "; ")
    }
  }
}

/// Where a caller gets the runtime. A test swaps in one that fails, as a renderer that can't start.
typealias GhosttyRuntimeSource = @MainActor () throws(GhosttyError) -> GhosttyRuntime

/// Builds a finalized configuration for an appearance.
typealias GhosttyConfigMaker =
  @MainActor (TerminalAppearance) throws(GhosttyError) -> ghostty_config_t

/// The process-wide libghostty runtime. Every terminal surface belongs to it.
///
/// libghostty requires one app per process, ticked on the main thread whenever its wakeup
/// callback fires. Configuration comes from ``TerminalAppearance``: Ghostty's own config files are
/// never read, so a user's `~/.config/ghostty` does not leak into Omnigent.
@MainActor
@safe
public final class GhosttyRuntime {
  private let parser = GhosttyParserThread()
  private static var instance: GhosttyRuntime?
  private static var isInitialized = false
  private static let logger = Logger(subsystem: "ai.omnigent", category: "terminal")

  /// The shared runtime, created on first use.
  ///
  /// - Throws: ``GhosttyError`` when libghostty cannot start or the configuration is invalid.
  public static func shared() throws(GhosttyError) -> GhosttyRuntime {
    if let instance { return instance }
    let runtime = unsafe try GhosttyRuntime(
      appearance: TerminalPreferences.load(over: TerminalAppearance.system()))
    instance = runtime
    return runtime
  }

  let app: ghostty_app_t
  private var config: ghostty_config_t
  /// The appearance every surface uses.
  public private(set) var appearance: TerminalAppearance
  private var surfaces: [ObjectIdentifier: WeakSurface] = [:]
  /// Builds the configuration for an appearance change. A test swaps it to model a refusal.
  var makeNextConfig: GhosttyConfigMaker = { appearance throws(GhosttyError) in
    unsafe try makeConfig(appearance)
  }

  private struct WeakSurface {
    weak var controller: TerminalSurfaceController?
  }

  init(
    appearance: TerminalAppearance,
    newApp: (UnsafePointer<ghostty_runtime_config_s>?, ghostty_config_t?) -> ghostty_app_t? = {
      unsafe ghostty_app_new($0, $1)
    }
  ) throws(GhosttyError) {
    try Self.initialize()
    let config = unsafe try Self.makeConfig(appearance)
    var runtime = unsafe ghostty_runtime_config_s()
    unsafe runtime.userdata = nil
    unsafe runtime.supports_selection_clipboard = false
    unsafe runtime.wakeup_cb = unsafe ghosttyWakeup
    unsafe runtime.action_cb = unsafe ghosttyAction
    unsafe runtime.read_clipboard_cb = unsafe ghosttyReadClipboard
    unsafe runtime.confirm_read_clipboard_cb = unsafe ghosttyConfirmReadClipboard
    unsafe runtime.write_clipboard_cb = unsafe ghosttyWriteClipboard
    unsafe runtime.close_surface_cb = unsafe ghosttyCloseSurface
    guard let app = unsafe newApp(&runtime, config) else {
      unsafe ghostty_config_free(config)
      throw .appCreationFailed
    }
    unsafe self.app = app
    unsafe self.config = config
    self.appearance = appearance
    unsafe ghostty_app_set_color_scheme(app, appearance.colorScheme.ghostty)
  }

  /// Starts libghostty, which every configuration call needs first.
  private static func initialize() throws(GhosttyError) {
    guard !isInitialized else { return }
    // libghostty parses argv only for `ghostty +action` CLI use; the embedder passes none.
    let status = unsafe ghostty_init(0, CommandLine.unsafeArgv)
    guard status == 0 else { throw .initFailed(code: status) }
    isInitialized = true
  }

  /// Builds and validates a finalized configuration.
  static func makeConfig(_ appearance: TerminalAppearance) throws(GhosttyError) -> ghostty_config_t
  {
    unsafe try makeConfig(
      text: GhosttyConfigText.make(appearance, systemFontFamily: TerminalFonts.systemFamily))
  }

  /// Builds and validates a finalized configuration from config-file text.
  static func makeConfig(text: String) throws(GhosttyError) -> ghostty_config_t {
    try initialize()
    guard let config = unsafe ghostty_config_new() else { throw .appCreationFailed }
    text.withCString { pointer in
      unsafe ghostty_config_load_string(config, pointer, UInt(text.utf8.count), "omnigent")
    }
    unsafe ghostty_config_finalize(config)
    let count = unsafe ghostty_config_diagnostics_count(config)
    if count > 0 {
      var messages: [String] = []
      for index in 0..<count {
        let diagnostic = unsafe ghostty_config_get_diagnostic(config, index)
        if let message = unsafe diagnostic.message {
          messages.append(unsafe String(cString: message))
        }
      }
      unsafe ghostty_config_free(config)
      throw .invalidConfiguration(messages)
    }
    return unsafe config
  }

  /// Checks that libghostty accepts the configuration for `appearance`.
  ///
  /// - Throws: ``GhosttyError/invalidConfiguration(_:)`` with Ghostty's messages.
  public static func validate(_ appearance: TerminalAppearance) throws(GhosttyError) {
    try initialize()
    let config = unsafe try makeConfig(appearance)
    unsafe ghostty_config_free(config)
  }

  /// Applies a new appearance to the runtime and every live surface.
  ///
  /// - Throws: ``GhosttyError/invalidConfiguration(_:)``; the old appearance stays in effect.
  public func update(appearance: TerminalAppearance) throws(GhosttyError) {
    guard appearance != self.appearance else { return }
    let next = unsafe try makeNextConfig(appearance)
    unsafe ghostty_app_update_config(app, next)
    unsafe ghostty_app_set_color_scheme(app, appearance.colorScheme.ghostty)
    for surface in surfaces.values.compactMap(\.controller) {
      unsafe surface.apply(config: next, colorScheme: appearance.colorScheme)
    }
    unsafe ghostty_config_free(config)
    unsafe config = next
    self.appearance = appearance
  }

  func register(_ controller: TerminalSurfaceController) {
    surfaces[ObjectIdentifier(controller)] = WeakSurface(controller: controller)
  }

  func unregister(_ controller: TerminalSurfaceController) {
    surfaces[ObjectIdentifier(controller)] = nil
  }

  /// A wakeup: ticks the shared runtime, or logs that none could start.
  static func tickAfterWakeup(from source: GhosttyRuntimeSource = shared) {
    do {
      try source().tick()
    } catch {
      log("wakeup without a runtime: \(error)")
    }
  }

  /// Runs libghostty's app-thread work. Called after every wakeup.
  func tick() {
    unsafe ghostty_app_tick(app)
  }

  /// Parses remote output for `surface`, draining libghostty's mailbox until it is done.
  func parse(_ surface: ghostty_surface_t, _ bytes: UnsafeBufferPointer<CChar>) {
    unsafe parser.process(surface, bytes) { tick() }
  }

  /// The app gained or lost focus.
  public func setFocused(_ focused: Bool) {
    unsafe ghostty_app_set_focus(app, focused)
  }

  static func log(_ message: String) {
    logger.error("\(message, privacy: .public)")
  }
}

extension TerminalColorScheme {
  var ghostty: ghostty_color_scheme_e {
    self == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
  }
}

// MARK: - C callbacks
//
// libghostty calls these from its own threads (wakeup) or from the app thread, which is the
// main thread because only the main thread ticks the app. Each one re-establishes main-actor
// isolation before touching Swift state, and reports a callback on any other thread as an
// error instead of racing.

/// The surface controller registered as a surface's userdata.
private nonisolated func controller(
  fromUserdata userdata: UnsafeMutableRawPointer?
) -> TerminalSurfaceController? {
  guard let userdata = unsafe userdata else { return nil }
  return unsafe Unmanaged<TerminalSurfaceController>.fromOpaque(userdata).takeUnretainedValue()
}

private nonisolated func ghosttyWakeup(_: UnsafeMutableRawPointer?) {
  Task { @MainActor in GhosttyRuntime.tickAfterWakeup() }
}

private nonisolated func ghosttyAction(
  _: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s
) -> Bool {
  guard Thread.isMainThread else {
    offMainThread("action_cb")
    return false
  }
  return MainActor.assumeIsolated {
    guard unsafe target.tag == GHOSTTY_TARGET_SURFACE,
      let surface = unsafe target.target.surface,
      let controller = unsafe controller(fromUserdata: ghostty_surface_userdata(surface))
    else { return false }
    return unsafe controller.handle(action: action)
  }
}

/// A pointer as a plain integer, so it can cross into a main-actor closure. The pointee is
/// owned by libghostty (a pending clipboard request) or by a live surface controller.
private nonisolated func address(_ pointer: UnsafeMutableRawPointer?) -> UInt {
  UInt(bitPattern: pointer)
}

private nonisolated func pointer(_ address: UInt) -> UnsafeMutableRawPointer? {
  unsafe UnsafeMutableRawPointer(bitPattern: address)
}

private nonisolated func offMainThread(_ callback: String) {
  Task { @MainActor in GhosttyRuntime.log("\(callback) was called off the main thread") }
}

nonisolated func ghosttyReadClipboard(
  _ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e,
  _ state: UnsafeMutableRawPointer?
) -> Bool {
  guard location == GHOSTTY_CLIPBOARD_STANDARD else { return false }
  guard Thread.isMainThread else {
    offMainThread("read_clipboard_cb")
    return false
  }
  let owner = unsafe address(userdata)
  let request = unsafe address(state)
  return MainActor.assumeIsolated {
    guard let controller = unsafe controller(fromUserdata: pointer(owner)) else { return false }
    unsafe controller.completePaste(state: pointer(request))
    return true
  }
}

nonisolated func ghosttyConfirmReadClipboard(
  _ userdata: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>?,
  _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e
) {
  guard Thread.isMainThread else {
    offMainThread("confirm_read_clipboard_cb")
    return
  }
  let owner = unsafe address(userdata)
  let pending = unsafe address(state)
  let content = unsafe text.map { unsafe String(cString: $0) } ?? ""
  let kind = request.rawValue
  MainActor.assumeIsolated {
    guard let controller = unsafe controller(fromUserdata: pointer(owner)) else { return }
    unsafe controller.confirmClipboard(
      content: content, state: pointer(pending), request: ghostty_clipboard_request_e(kind))
  }
}

nonisolated func ghosttyWriteClipboard(
  _ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e,
  _ contents: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int, _ confirm: Bool
) {
  guard location == GHOSTTY_CLIPBOARD_STANDARD, let contents = unsafe contents, count > 0 else {
    return
  }
  guard Thread.isMainThread else {
    offMainThread("write_clipboard_cb")
    return
  }
  var text: String?
  for index in 0..<count {
    let item = unsafe contents[index]
    guard let mime = unsafe item.mime, let data = unsafe item.data else { continue }
    if unsafe String(cString: mime) == "text/plain" {
      text = unsafe String(cString: data)
    }
  }
  guard let text else { return }
  let owner = unsafe address(userdata)
  MainActor.assumeIsolated {
    guard let controller = unsafe controller(fromUserdata: pointer(owner)) else { return }
    controller.copied(text: text, requiresConfirmation: confirm)
  }
}

nonisolated func ghosttyCloseSurface(_: UnsafeMutableRawPointer?, _: Bool) {
  // A remote (manual I/O) surface has no child process, so Ghostty never asks to close it for
  // an exit. The attach state machine reports a closed terminal instead.
}
