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
      // SwiftUI controls, sheets, pickers and links take the theme's tint instead of system blue,
      // and so do UIKit's alerts. The window keeps the system tint, so the keyboard focus ring
      // stays neutral as the web's does, not the primary pink.
      .tint(ThemeColor.controlTint)
      .background { AlertTint() }
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

/// Gives the alerts UIKit presents the theme's control tint (SwiftUI's `.tint` doesn't reach
/// them). The color carries both schemes, so a dark-mode switch restyles them without a SwiftUI
/// update; a theme change applies to the next alert.
private struct AlertTint: UIViewRepresentable {
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
      guard tints.count == 2 else { return }
      UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor =
        .adaptive(light: tints[0], dark: tints[1])
    }
  }
}

extension UIColor {
  /// `light` or `dark` by the traits' interface style. Nonisolated, so its provider is too:
  /// SwiftUI's async renderer resolves tints off the main thread mid-animation.
  nonisolated static func adaptive(light: UIColor, dark: UIColor) -> UIColor {
    UIColor { $0.userInterfaceStyle == .dark ? dark : light }
  }
}
