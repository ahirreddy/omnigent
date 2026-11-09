import AppKit
import OSLog

/// A replacement of AppKit methods that crash, and what stays unguarded without them.
struct AppKitGuard {
  /// Installs it, and returns whether AppKit had the methods.
  let install: () -> Bool
  /// What is left unguarded when it can't install.
  let missing: String
}

extension OmnigentMacAppDelegate {
  /// The guards of AppKit's crashes this edition installs.
  static var appKitGuards: [AppKitGuard] {
    var guards = [
      AppKitGuard(
        install: { ToolbarSwapGuard.install() },
        missing: "AppKit lacks the toolbar methods to guard; toolbar swaps are unguarded."),
      AppKitGuard(
        install: { MenuTitleGuard.install() },
        missing: "AppKit lacks the menu item title setter; nil titles are unguarded."),
      AppKitGuard(
        install: { TableRowGuard.install() },
        missing: "AppKit lacks the table row methods; drags and menus on removed rows quit."),
      AppKitGuard(
        install: { WindowsMenuGuard.install() },
        missing: "AppKit lacks the Windows menu methods; arranging while a window changes quits."),
      AppKitGuard(
        install: { SingleLinePasteGuard.install() },
        missing: "AppKit lacks the text view paste method; pasted lines stay unjoined."),
    ]
    #if OMNIGENT_CHROMIUM
      guards.append(
        AppKitGuard(
          install: { ScrollMonitorGuard.install() },
          missing: "AppKit lacks the scroll monitor to guard; its resumes are unguarded."))
    #endif
    return guards
  }

  /// Installs `guards`, and logs each one this AppKit has no methods for.
  /// - Parameters:
  ///   - guards: The guards.
  ///   - logger: Where what is left unguarded goes.
  /// - Returns: What is left unguarded.
  @discardableResult
  static func install(_ guards: [AppKitGuard], logger: Logger) -> [String] {
    let missing = guards.filter { !$0.install() }.map(\.missing)
    for message in missing { logger.error("\(message, privacy: .public)") }
    return missing
  }
}
