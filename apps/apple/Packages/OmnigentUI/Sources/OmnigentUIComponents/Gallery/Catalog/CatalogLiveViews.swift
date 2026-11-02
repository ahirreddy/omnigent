import SwiftUI

/// An existing interactive playground, filling the detail.
struct CatalogLiveCanvas: View {
  let make: @MainActor (CatalogContext) -> AnyView
  @Bindable var settings: CatalogSettings
  let screen: CatalogScreen
  @State private var content: AnyView?

  var body: some View {
    Group {
      if let content {
        content
          .catalogTraits(settings.traits(settings.appearance.schemes[0], screen: screen))
      } else {
        Color.clear
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      if content == nil {
        content = make(settings.context(screen))
      }
    }
  }
}

#if os(iOS)
  /// A state at this device's real size, over the whole screen.
  struct CatalogFullScreen: View {
    let state: CatalogState
    @Bindable var settings: CatalogSettings
    let canvas: CatalogCanvas
    let close: () -> Void
    @State private var content: AnyView?

    var body: some View {
      Group {
        if let content {
          content.catalogTraits(
            settings.traits(
              settings.appearance.schemes[0], screen: CatalogScreen(.platformDefault)))
        } else {
          Color.clear
        }
      }
      .themeCanvas()
      .overlay(alignment: .topTrailing) {
        Button("Close", systemImage: "xmark.circle.fill", action: close)
          .labelStyle(.iconOnly)
          .font(.title)
          .padding()
          .accessibilityIdentifier("gallery-full-screen-close")
      }
      .onAppear {
        if content == nil {
          content = state.make(settings.context(CatalogScreen(.platformDefault)))
        }
      }
    }
  }
#endif
