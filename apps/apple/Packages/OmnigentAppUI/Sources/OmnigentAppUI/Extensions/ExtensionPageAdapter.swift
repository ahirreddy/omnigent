import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// An extension's page at `/extensions/<extension id>/<route>`: a spinner while the extensions
/// are read, the page once its extension lists it, else "Page not found", as the web's
/// `ExtensionPageRoute`. The page mounts while it shows and is torn down when it leaves.
struct ExtensionPageAdapter: View {
  let connection: ConnectionStore
  let extensionID: String
  let route: String
  /// Shows a destination: another page of the extension, or a session.
  let show: @MainActor (SidebarDestination) -> Void
  /// Opens New session, filed into a project when given.
  let newSession: @MainActor (ProjectSummary?) -> Void

  @State private var controller: ExtensionPageController?
  @Environment(\.openURL) private var openURL

  var body: some View {
    Group {
      if let controller {
        ExtensionPageView(
          state: controller.state, channel: controller.channel,
          actions: ExtensionPageActions(
            retry: { controller.retry() },
            themeChanged: { controller.themeChanged(dark: $0) }))
      } else {
        ExtensionPageView(
          state: ExtensionPageState(title: "", phase: isReading ? .loading : .notFound),
          channel: ExtensionFrameChannel(), actions: .inert)
      }
    }
    .task(id: mountKey) { mount() }
    .onDisappear { controller?.stop() }
  }

  private var resolved: (Extension, ExtensionPage)? {
    connection.extensions?.page(extensionID: extensionID, route: route)
  }

  private var isReading: Bool { connection.extensions?.isLoading == true }

  /// Changes when the page changes or its extension is first listed.
  private var mountKey: String {
    "\(extensionID)/\(route)/\(resolved?.1.id ?? "")"
  }

  private func mount() {
    guard let resolved else {
      controller?.stop()
      controller = nil
      return
    }
    let (item, page) = resolved
    if let controller, controller.matches(item, page) {
      controller.start()
      return
    }
    controller?.stop()
    let made = Self.controller(
      item, page: page, connection: connection,
      routes: ExtensionNavigationRoutes(
        show: show, newSession: newSession, openExternal: { openURL($0) }))
    controller = made
    made.start()
  }

  /// A mount of `page` over the connection's core, extensions and lists.
  static func controller(
    _ item: Extension, page: ExtensionPage, connection: ConnectionStore,
    routes: ExtensionNavigationRoutes
  ) -> ExtensionPageController {
    let server = connection.connectedServer
    let storage = server.map {
      ExtensionUserStorage(server: $0.baseUrl, userID: $0.userId, extensionID: item.id)
    }
    let services = LiveExtensionHostServices(
      extensionItem: item, connection: connection, routes: routes, storage: storage)
    let extensions = connection.extensions
    let core = connection.core
    let controller = ExtensionPageController(
      extensionItem: item, page: page,
      bundle: ExtensionBundleSource(
        read: { extensionID, url in
          guard let core else { throw LiveExtensionHostServices.unavailable("Extension bundle") }
          return try await core.extensionAsset(extensionId: extensionID, url: url)
        },
        refresh: { await extensions?.reload() ?? [] }),
      services: services)
    services.isDark = { [weak controller] in controller?.isDark ?? false }
    return controller
  }
}
