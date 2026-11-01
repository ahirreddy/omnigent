#if os(macOS)
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Renders every gallery surface in light and dark, at Mac and compact widths, through a real
  /// hosting view. Each render must produce a correctly sized, non-blank image, and dark must
  /// differ from light. With `OMNIGENT_UI_RENDER_DIR` set, the images are written as
  /// `ui-<surface>-<width>-<scheme>.png` for review.
  @Suite("Gallery rendering", .serialized)
  struct GalleryRenderTests {
    nonisolated struct Surface: CustomTestStringConvertible, Sendable {
      let name: String
      let regular: CGSize
      let compactHeight: CGFloat?
      let make: @MainActor @Sendable () -> AnyView

      var testDescription: String { name }
    }

    nonisolated static let surfaces: [Surface] = [
      Surface(name: "app", regular: CGSize(width: 1_280, height: 860), compactHeight: 844) {
        AnyView(GalleryAppLayout(inlineInspector: true))
      },
      Surface(name: "transcript", regular: CGSize(width: 820, height: 0), compactHeight: nil) {
        AnyView(GalleryTranscript().padding(20))
      },
      Surface(name: "decisions", regular: CGSize(width: 760, height: 0), compactHeight: nil) {
        AnyView(GalleryDecisions().padding(20))
      },
      Surface(name: "composer", regular: CGSize(width: 760, height: 0), compactHeight: nil) {
        AnyView(GalleryComposer().padding(20))
      },
      Surface(name: "sessions", regular: CGSize(width: 300, height: 860), compactHeight: 844) {
        AnyView(GallerySessionList())
      },
      Surface(name: "new-session", regular: CGSize(width: 560, height: 760), compactHeight: 844) {
        AnyView(GalleryNewSession())
      },
      Surface(name: "inspector", regular: CGSize(width: 340, height: 1_560), compactHeight: nil) {
        AnyView(GalleryPageContent(page: .inspector))
      },
      Surface(name: "inspector-terminals", regular: CGSize(width: 340, height: 600), compactHeight: nil)
      {
        AnyView(
          WorkspaceInspector(
            state: PreviewData.shellConversation, actions: ConversationActions(),
            slots: WorkspaceSlots(
              terminals: AnyView(
                List {
                  Label("zsh \u{00B7} u-4f2k9q", systemImage: "terminal")
                  Label("claude \u{00B7} main", systemImage: "sparkles.rectangle.stack")
                })),
            tab: .constant(.terminals)))
      },
      Surface(name: "markdown", regular: CGSize(width: 760, height: 0), compactHeight: nil) {
        AnyView(GalleryPageContent(page: .markdown).padding(20))
      },
      Surface(name: "inbox", regular: CGSize(width: 760, height: 700), compactHeight: 844) {
        AnyView(NavigationStack { InboxView(state: PreviewData.inbox, actions: InboxActions()) })
      },
      Surface(name: "themes", regular: CGSize(width: 1_000, height: 0), compactHeight: nil) {
        AnyView(ThemeGalleryView().frame(height: 1_100))
      },
      Surface(name: "server-settings", regular: CGSize(width: 900, height: 560), compactHeight: 844)
      {
        AnyView(
          ServerSettingsView(
            state: PreviewData.serverSettings, selectedServer: .constant("dbx"),
            actions: ServerSettingsActions()))
      },
    ]

    @Test("renders in light and dark at Mac and compact widths", arguments: surfaces)
    func render(surface: Surface) throws {
      for layout in [LayoutWidth.regular, .compact] {
        let width = layout == .regular ? surface.regular.width : 390
        let fixedHeight = layout == .regular ? surface.regular.height : (surface.compactHeight ?? 0)
        let height: CGFloat? = fixedHeight > 0 ? fixedHeight : nil
        var coverage: [ColorScheme: Double] = [:]
        var averages: [ColorScheme: Double] = [:]
        for scheme in [ColorScheme.light, .dark] {
          let rendered = try RenderSupport.render(
            surface.make(), width: width, height: height, scheme: scheme, layout: layout)
          #expect(rendered.size.width >= width, "\(surface.name) rendered narrower than requested")
          if let height { #expect(rendered.size.height >= height) }
          coverage[scheme] = RenderSupport.inkCoverage(rendered)
          averages[scheme] = RenderSupport.averageLuminance(rendered)
          let widthName = layout == .regular ? "mac" : "compact"
          let schemeName = scheme == .light ? "light" : "dark"
          try RenderSupport.write(rendered, name: "ui-\(surface.name)-\(widthName)-\(schemeName)")
        }
        for scheme in [ColorScheme.light, .dark] {
          #expect(
            (coverage[scheme] ?? 0) > 0.01,
            "\(surface.name) \(layout) \(scheme) looks blank")
        }
        #expect(
          (averages[.light] ?? 0) > (averages[.dark] ?? 1),
          "\(surface.name) \(layout): dark should be darker than light")
      }
    }
  }
#endif
