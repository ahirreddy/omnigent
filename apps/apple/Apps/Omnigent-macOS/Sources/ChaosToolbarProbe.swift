#if DEBUG
  import AppKit
  import ObjectiveC

  /// Logs every `NSWindow.toolbar` assignment during a chaos run, with how deeply it nests in
  /// another, so a toolbar swap that re-enters itself shows in the log before it crashes.
  @MainActor
  enum ChaosToolbarProbe {
    fileprivate static var write: (String) -> Void = { _ in }
    fileprivate static var depth = 0

    /// Starts logging through `write`.
    /// - Returns: Whether the probe could be installed.
    @discardableResult
    static func install(write: @escaping (String) -> Void) -> Bool {
      self.write = write
      let setter = #selector(setter: NSWindow.toolbar)
      let probe = #selector(NSWindow.chaosProbeSetToolbar(_:))
      guard let original = unsafe class_getInstanceMethod(NSWindow.self, setter),
        let replacement = unsafe class_getInstanceMethod(NSWindow.self, probe)
      else { return false }
      unsafe method_exchangeImplementations(original, replacement)
      return true
    }

    fileprivate static func describe(_ toolbar: NSToolbar?) -> String {
      guard let toolbar else { return "none" }
      return "\(toolbar.identifier) items=\(toolbar.items.count)"
    }
  }

  extension NSWindow {
    /// After the exchange this is `setToolbar:`, and calling it calls the original.
    @objc fileprivate func chaosProbeSetToolbar(_ toolbar: NSToolbar?) {
      ChaosToolbarProbe.depth += 1
      defer { ChaosToolbarProbe.depth -= 1 }
      let depth = ChaosToolbarProbe.depth
      var line =
        "TOOLBAR depth=\(depth) window=\"\(title)\" sheet=\(attachedSheet != nil) "
        + "\(ChaosToolbarProbe.describe(self.toolbar)) -> \(ChaosToolbarProbe.describe(toolbar))"
      if depth > 1 {
        line += "\n" + Thread.callStackSymbols.prefix(60).joined(separator: "\n")
      }
      ChaosToolbarProbe.write(line)
      chaosProbeSetToolbar(toolbar)
    }
  }
#endif
