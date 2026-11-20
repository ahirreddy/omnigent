public import Foundation
public import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// The server operator's branding, as the web's `useBranding`: the name the app calls itself, the
/// logo in place of the mascot, and whether "Powered by Omnigent" shows.
nonisolated public struct AppBranding: Hashable, Sendable {
  /// The built-in name.
  public static let defaultAppName = "Omnigent"

  /// The operator's name for the app, when set.
  public var appName: String?
  /// The main logo's image bytes, once read.
  public var logo: Data?
  /// "Powered by Omnigent" shows under the new-session page.
  public var poweredBy: Bool

  /// Creates branding.
  public init(appName: String? = nil, logo: Data? = nil, poweredBy: Bool = false) {
    self.appName = appName
    self.logo = logo
    self.poweredBy = poweredBy
  }

  /// The name to show: the operator's, else "Omnigent".
  public var name: String { appName ?? Self.defaultAppName }

  /// The logo as an image; `nil` when there is none or it doesn't decode, and the mascot shows.
  public var logoImage: Image? {
    guard let logo else { return nil }
    #if os(macOS)
      return NSImage(data: logo).map { Image(nsImage: $0) }
    #else
      return UIImage(data: logo).map { Image(uiImage: $0) }
    #endif
  }
}

extension EnvironmentValues {
  /// The connected server's branding; `nil` for the built-in look.
  @Entry public var appBranding: AppBranding?
}

/// "Powered by [Otto] Omnigent", under a branded new-session page, as the web's footer.
struct PoweredByFooter: View {
  var body: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      Text("Powered by")
      OttoView(gaze: .zero)
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
      Text(AppBranding.defaultAppName).fontWeight(.medium)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("new-session-powered-by")
  }
}
