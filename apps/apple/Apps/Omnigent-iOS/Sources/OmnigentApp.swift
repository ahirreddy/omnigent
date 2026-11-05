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
      // The window's tint is SwiftUI's default accent and UIKit's: sheets, pickers, links,
      // alerts and menus take the theme's instead of system blue. Toolbar glyphs stay neutral.
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

/// Sets the hosting window's tint to the theme's control tint, which SwiftUI controls without
/// their own tint and the alerts, dialogs and menus UIKit presents all follow. The color carries
/// both schemes, so a dark-mode switch restyles them without a SwiftUI update.
private struct WindowTint: UIViewRepresentable {
  func makeUIView(context: Context) -> TintView {
    let view = TintView()
    view.isUserInteractionEnabled = false
    return view
  }

  func updateUIView(_ view: TintView, context: Context) {
    view.tints = [ColorScheme.light, .dark].map { scheme in
      var environment = context.environment
      environment.colorScheme = scheme
      return UIColor(ThemeColor.controlTint.resolve(in: environment))
    }
  }

  final class TintView: UIView {
    /// The tint in light and dark mode; setting the same pair again changes nothing.
    var tints: [UIColor] = [] {
      didSet { if tints != oldValue { applyTint() } }
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      applyTint()
    }

    private func applyTint() {
      guard let window, tints.count == 2 else { return }
      let (light, dark) = (tints[0], tints[1])
      window.tintColor = UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
  }
}
