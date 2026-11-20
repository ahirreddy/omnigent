import Foundation

extension PreviewData {
  /// An extension's page whose bundle the server no longer has.
  static let extensionPage = ExtensionPageState(
    title: "Hello Extension", phase: .failed("Extension script failed to load (404)"))

  /// The sidebar entry of the example extension.
  static let extensionEntry = SidebarExtensionEntry(
    id: "example.hello-page.nav", label: "Hello Extension", icon: "puzzle",
    extensionID: "example.hello-page", route: "hello")
}
