public import SwiftUI

extension EnvironmentValues {
  /// A live remote browser tab (`OmnigentRemoteBrowser` on its fixture host) for the playground
  /// and gallery, which cannot depend on it; `nil` shows a static sample page.
  @Entry public var remoteBrowserPreview: AnyView?
}
