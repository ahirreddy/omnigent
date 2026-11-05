import OSLog
import OmnigentAppUI
import OmnigentUIComponents
import SwiftUI

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
