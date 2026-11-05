import OSLog
import OmnigentAppUI
import OmnigentUIComponents
import SwiftUI
import UIKit

@main
struct OmnigentApp: App {
  @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
  @State private var theme = ThemePreferences()

  var body: some Scene {
    // iPad windows open with a request (Open in New Window, tab tear-off); the first window and
    // those the system opens have none.
    WindowGroup(for: PhoneWindowRequest.self) { $request in
      #if DEBUG
        if let gallery = Self.gallery {
          // Debug builds launched with -OmnigentGallery show the component gallery instead.
          GalleryCatalogView(options: gallery)
        } else {
          root(request)
        }
      #else
        root(request)
      #endif
    }
    .commands {
      SidebarCommands()
      OmnigentServerCommands()
      OmnigentSessionCommands()
      OmnigentTabCommands()
    }
  }

  private func root(_ request: PhoneWindowRequest?) -> some View {
    IOSRootView(request: request)
      // Sheets, pickers, toggles and bar buttons take the theme accent, as the web's controls
      // do; the window's tint carries it to alerts and menus UIKit presents.
      .tint(ThemeColor.controlTint)
      .background { WindowTint() }
      .appearanceSettings(theme)
      .omnigentTheme(theme.theme, appearance: theme.mode)
  }

  #if DEBUG
    /// The gallery's launch options when `-OmnigentGallery` asked for it; a bad option is logged
    /// and the app starts normally.
    private static let gallery: GalleryLaunchOptions? = {
      do {
        let options = try GalleryLaunchOptions(
          arguments: ProcessInfo.processInfo.arguments,
          environment: ProcessInfo.processInfo.environment)
        return options.showsGallery ? options : nil
      } catch {
        Logger(subsystem: "ai.omnigent.ios", category: "gallery").error(
          "Gallery launch options: \(String(describing: error), privacy: .public)")
        return nil
      }
    }()
  #endif
}

/// Sets the hosting window's tint to the theme's control tint, so alerts, confirmation dialogs
/// and menus that UIKit presents outside the SwiftUI tree match the app.
private struct WindowTint: UIViewRepresentable {
  func makeUIView(context: Context) -> TintView {
    let view = TintView()
    view.isUserInteractionEnabled = false
    return view
  }

  func updateUIView(_ view: TintView, context: Context) {
    view.tint = UIColor(ThemeColor.controlTint.resolve(in: context.environment))
  }

  final class TintView: UIView {
    var tint: UIColor? {
      didSet { applyTint() }
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      applyTint()
    }

    private func applyTint() {
      guard let window, let tint, window.tintColor != tint else { return }
      window.tintColor = tint
    }
  }
}
