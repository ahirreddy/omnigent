#if DEBUG
  import AppKit
  import ObjectiveC

  /// Logs every `NSWindow.toolbar` assignment during a chaos run, with how deeply it nests in
  /// another, so a toolbar swap that re-enters itself shows in the log before it crashes. Like
  /// ``ToolbarSwapGuard`` its replacement is nonisolated and reads the window through KVC.
  enum ChaosToolbarProbe {
    /// Set once before the exchange; read on the main thread.
    nonisolated(unsafe) fileprivate static var write: (String) -> Void = { _ in }
    nonisolated(unsafe) fileprivate static var depth = 0

    /// Starts logging through `write`.
    /// - Returns: Whether the probe could be installed.
    @MainActor @discardableResult
    static func install(write: @escaping (String) -> Void) -> Bool {
      unsafe self.write = write
      let setter = #selector(setter: NSWindow.toolbar)
      let probe = #selector(NSWindow.chaosProbeSetToolbar(_:))
      guard let original = unsafe class_getInstanceMethod(NSWindow.self, setter),
        let replacement = unsafe class_getInstanceMethod(NSWindow.self, probe)
      else { return false }
      unsafe method_exchangeImplementations(original, replacement)
      return true
    }

    nonisolated fileprivate static func describe(_ toolbar: NSObject?) -> String {
      guard let toolbar else { return "none" }
      let identifier = toolbar.value(forKey: "identifier") as? String ?? "?"
      let items = (toolbar.value(forKey: "items") as? [Any])?.count ?? 0
      return "\(identifier) items=\(items)"
    }
  }

  extension NSWindow {
    /// After the exchange this is `setToolbar:`, and calling it calls the original.
    @objc nonisolated fileprivate func chaosProbeSetToolbar(_ toolbar: NSToolbar?) {
      unsafe ChaosToolbarProbe.depth += 1
      defer { unsafe ChaosToolbarProbe.depth -= 1 }
      let depth = unsafe ChaosToolbarProbe.depth
      let title = value(forKey: "title") as? String ?? ""
      let hasSheet = value(forKey: "attachedSheet") != nil
      let current = value(forKey: "toolbar") as? NSObject
      var line =
        "TOOLBAR depth=\(depth) window=\"\(title)\" sheet=\(hasSheet) "
        + "\(ChaosToolbarProbe.describe(current)) -> \(ChaosToolbarProbe.describe(toolbar))"
      if depth > 1 {
        line += "\n" + Thread.callStackSymbols.prefix(60).joined(separator: "\n")
      }
      unsafe ChaosToolbarProbe.write(line)
      chaosProbeSetToolbar(toolbar)
    }
  }
#endif
