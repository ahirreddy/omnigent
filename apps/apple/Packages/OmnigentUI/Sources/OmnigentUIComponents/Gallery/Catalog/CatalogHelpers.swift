import SwiftUI

extension CatalogEntry {
  /// A component: a column that grows to fit unless `canvas` says otherwise.
  static func component(
    _ area: CatalogArea, _ name: String, _ title: String, summary: String,
    systemImage: String = "square.dashed", canvas: CatalogCanvas = .column(width: 640),
    keywords: [String] = [], states: [CatalogState],
    live: (@MainActor (CatalogContext) -> AnyView)? = nil
  ) -> Self {
    Self(
      .components, area, name, title: title, summary: summary, systemImage: systemImage,
      canvas: canvas, keywords: keywords, states: states, live: live)
  }

  /// A whole page, sized by the device.
  static func page(
    _ area: CatalogArea, _ name: String, _ title: String, summary: String,
    systemImage: String = "macwindow", canvas: CatalogCanvas = .anyDevice,
    keywords: [String] = [], states: [CatalogState],
    live: (@MainActor (CatalogContext) -> AnyView)? = nil
  ) -> Self {
    Self(
      .pages, area, name, title: title, summary: summary, systemImage: systemImage, canvas: canvas,
      keywords: keywords, states: states, live: live)
  }

  /// A flow from a script.
  static func flow<Model>(
    _ area: CatalogArea, _ name: String, _ title: String, summary: String,
    systemImage: String = "arrow.triangle.turn.up.right.diamond",
    canvas: CatalogCanvas = .anyDevice, keywords: [String] = [],
    script: CatalogFlowScript<Model>, live: (@MainActor (CatalogContext) -> AnyView)? = nil
  ) -> Self {
    Self(
      .flows, area, name, title: title, summary: summary, systemImage: systemImage, canvas: canvas,
      keywords: keywords, states: script.states, live: live)
  }
}

/// A titled sample value, for building one state per sample.
struct CatalogSampleItem<Value> {
  let id: String
  let title: String
  let value: Value

  init(_ id: String, _ title: String, _ value: Value) {
    self.id = id
    self.title = title
    self.value = value
  }
}

/// A captioned sample inside a component state, for showing variants together.
struct CatalogSample<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text(title)
        .font(Theme.Typography.section)
        .foregroundStyle(.secondary)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A padded column of samples on the theme canvas.
struct CatalogStack<Content: View>: View {
  var spacing: CGFloat = Theme.Spacing.extraLarge
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) { content }
      .padding(Theme.Spacing.extraLarge)
      .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

/// No-op actions beyond the gallery's own, for catalog states.
enum CatalogActions {
  static let inbox = InboxActions(
    open: { _ in }, markRead: { _ in }, reply: { _, _ in }, respond: { _, _ in })

  static let sidebar = GalleryActions.sidebar { _ in }

  static let newTab = NewTabPageActions(
    newSession: {}, newTerminal: { _, _ in }, openBrowser: {}, openSession: { _ in })
}
