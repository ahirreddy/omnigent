import AppKit
import OmnigentAppUI
import OmnigentDesktop
import OmnigentWorkspaceUI
import SwiftUI

/// Asks before unsaved file edits would be lost, as a Mac document app does: Save, Don't Save
/// or Cancel, when a window closes or the app quits.
enum UnsavedEditsAlert {
  /// The person's answer.
  enum Choice {
    case save, discard, cancel
  }

  /// The question for `paths`.
  static func alert(for paths: [String]) -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = UnsavedFileEdits.title(for: paths)
    alert.informativeText =
      paths.count > 1
      ? "\(UnsavedFileEdits.message)\n\n\(paths.joined(separator: "\n"))" : UnsavedFileEdits.message
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Don't Save").hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
    return alert
  }

  /// The choice a button of ``alert(for:)`` stands for.
  static func choice(_ response: NSApplication.ModalResponse) -> Choice {
    switch response {
    case .alertFirstButtonReturn: .save
    case .alertSecondButtonReturn: .discard
    default: .cancel
    }
  }

  /// Says which files could not be saved; nothing closes.
  static func showFailure(_ paths: [String], in window: NSWindow?) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Some files could not be saved."
    alert.informativeText =
      "\(paths.joined(separator: "\n"))\n\nOpen them to see why, then save or discard the changes."
    if let window {
      alert.beginSheetModal(for: window)
    } else {
      Task { _ = await ModalLoop.run { alert.runModal() } }
    }
  }
}

/// Asks before the window closes while its workspaces hold unsaved file edits. SwiftUI owns the
/// window's delegate, so this one stands in front of it and forwards everything else.
@MainActor
final class UnsavedEditsWindowGuard: NSObject, NSWindowDelegate {
  /// SwiftUI's delegate, set on the main actor; also read by the nonisolated forwarding methods.
  /// Held strongly: the window subscribes this guard to every delegate notification the original
  /// answers, and one forwarded to a released original is an unrecognized selector.
  nonisolated(unsafe) private var original: (any NSWindowDelegate)?
  private weak var window: NSWindow?
  private let unsaved: () -> [String]
  private let save: () async -> [String]
  private let discard: () -> Void

  init(
    unsaved: @escaping () -> [String], save: @escaping () async -> [String],
    discard: @escaping () -> Void
  ) {
    self.unsaved = unsaved
    self.save = save
    self.discard = discard
  }

  /// Stands in front of `window`'s delegate, again whenever SwiftUI replaced it. A guard left by
  /// an earlier view of the window is replaced, not wrapped, so guards never chain.
  func install(on window: NSWindow) {
    if let installed = self.window, installed !== window { uninstall() }
    guard window.delegate !== self else { return }
    let current = window.delegate
    if let earlier = current as? UnsavedEditsWindowGuard {
      unsafe original = unsafe earlier.original
      earlier.window = nil
    } else {
      unsafe original = current
    }
    self.window = window
    window.delegate = self
  }

  /// Hands the window back to the delegate this guard stood in front of.
  func uninstall() {
    if let window, window.delegate === self { window.delegate = unsafe original }
    window = nil
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if unsafe original?.windowShouldClose?(sender) == false { return false }
    let paths = unsaved()
    guard !paths.isEmpty else { return true }
    UnsavedEditsAlert.alert(for: paths).beginSheetModal(for: sender) { [weak self] response in
      guard let self else { return }
      switch UnsavedEditsAlert.choice(response) {
      case .cancel:
        return
      case .discard:
        self.discard()
        sender.close()
      case .save:
        Task {
          let left = await self.save()
          guard left.isEmpty else { return UnsavedEditsAlert.showFailure(left, in: sender) }
          sender.close()
        }
      }
    }
    return false
  }

  nonisolated override func responds(to selector: Selector?) -> Bool {
    super.responds(to: selector) || (unsafe original?.responds(to: selector) ?? false)
  }

  nonisolated override func forwardingTarget(for selector: Selector?) -> Any? {
    let original = unsafe original
    return original?.responds(to: selector) == true
      ? original : super.forwardingTarget(for: selector)
  }
}

/// Installs an ``UnsavedEditsWindowGuard`` on the window showing this view.
struct UnsavedEditsWindowAccessor: NSViewRepresentable {
  let session: ServerSession

  func makeCoordinator() -> UnsavedEditsWindowGuard {
    UnsavedEditsWindowGuard(
      unsaved: { [weak session] in session?.unsavedFilePaths ?? [] },
      save: { [weak session] in await session?.saveUnsavedFiles() ?? [] },
      discard: { [weak session] in session?.discardUnsavedFiles() })
  }

  func makeNSView(context: Context) -> NSView {
    let view = WindowWatcher()
    view.onWindow = { [guardian = context.coordinator] window in guardian.install(on: window) }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    if let window = unsafe view.window { context.coordinator.install(on: window) }
  }

  static func dismantleNSView(_ view: NSView, coordinator: UnsavedEditsWindowGuard) {
    coordinator.uninstall()
  }

  private final class WindowWatcher: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window = unsafe window { onWindow?(window) }
    }
  }
}

/// Quitting with unsaved file edits: Save (quits once all are saved), Don't Save, or Cancel.
struct UnsavedEditsQuit {
  /// Asks about `paths`; the default shows ``UnsavedEditsAlert/alert(for:)`` and waits.
  var ask: ([String]) -> UnsavedEditsAlert.Choice = { paths in
    UnsavedEditsAlert.choice(UnsavedEditsAlert.alert(for: paths).runModal())
  }
  /// Saves every edit, and returns the paths that could not be saved.
  var saveAll: () async -> [String] = { await UnsavedFileEdits.saveAll() }
  /// Throws every edit away.
  var discardAll: () -> Void = { UnsavedFileEdits.discardAll() }
  /// Says the failure when saving leaves files unsaved.
  var showFailure: ([String]) -> Void = { UnsavedEditsAlert.showFailure($0, in: nil) }

  /// Asks before quitting when `paths` hold edits.
  /// - Parameters:
  ///   - paths: The files with unsaved edits.
  ///   - reply: Tells the app, later, whether to quit.
  ///   - proceed: Continues quitting.
  /// - Returns: The reply.
  func run(
    paths: [String], reply: @escaping (Bool) -> Void,
    proceed: @escaping () -> NSApplication.TerminateReply
  ) -> NSApplication.TerminateReply {
    guard !paths.isEmpty else { return proceed() }
    switch ask(paths) {
    case .cancel:
      return .terminateCancel
    case .discard:
      discardAll()
      return proceed()
    case .save:
      Task {
        let left = await saveAll()
        guard left.isEmpty else {
          reply(false)
          return showFailure(left)
        }
        switch proceed() {
        case .terminateNow: reply(true)
        case .terminateCancel: reply(false)
        case .terminateLater: break  // `proceed` replies once its own work is done.
        @unknown default: reply(true)
        }
      }
      return .terminateLater
    }
  }
}

extension OmnigentMacAppDelegate {
  /// Before quitting with unsaved file edits: Save (quits once all are saved), Don't Save, or
  /// Cancel.
  /// - Parameters:
  ///   - sender: The app.
  ///   - quit: What asks; `nil` in a test host, which quits without asking.
  ///   - paths: The files with unsaved edits.
  ///   - proceed: Continues quitting.
  /// - Returns: The reply.
  func askAboutUnsavedEdits(
    _ sender: NSApplication, quit: UnsavedEditsQuit?, paths: [String],
    then proceed: @escaping () -> NSApplication.TerminateReply
  ) -> NSApplication.TerminateReply {
    guard let quit else { return proceed() }
    return quit.run(
      paths: paths, reply: sender.reply(toApplicationShouldTerminate:), proceed: proceed)
  }
}
