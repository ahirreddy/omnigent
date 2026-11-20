import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI
import os

/// Puts the connected server's branding in the environment: its app name, the main logo once
/// read, and whether "Powered by Omnigent" shows.
struct ServerBrandingEnvironment: ViewModifier {
  let connection: ConnectionStore
  @State private var logo: Data?

  private var branding: ServerBranding? { connection.pages?.offered?.branding }

  func body(content: Content) -> some View {
    content
      .environment(\.appBranding, Self.appBranding(branding, logo: logo))
      .task(id: branding?.logoMain) { await readLogo(branding?.logoMain) }
  }

  /// The environment's branding: `nil` (the built-in look) when the server sets none.
  static func appBranding(_ branding: ServerBranding?, logo: Data?) -> AppBranding? {
    guard let branding else { return nil }
    return AppBranding(appName: branding.appName, logo: logo, poweredBy: branding.poweredBy)
  }

  private func readLogo(_ path: String?) async {
    guard let path, let core = connection.core else {
      logo = nil
      return
    }
    do {
      logo = Data(try await core.brandingLogo(path: path))
    } catch {
      // As the web's logo on a load error: the mascot shows instead.
      logo = nil
      Logger(subsystem: "ai.omnigent.app", category: "branding").error(
        "Could not read the server's logo: \(error.localizedDescription, privacy: .public)")
    }
  }
}
