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
      Surface(name: "reading-column", regular: CGSize(width: 834, height: 0), compactHeight: nil) {
        AnyView(
          VStack(spacing: Theme.Spacing.row) {
            VStack(alignment: .leading, spacing: Theme.Spacing.row) {
              MessageRowView(
                row: Row(id: "short", role: .user, text: "Looks good."),
                decoration: MessageDecoration())
              MessageRowView(
                row: Row(id: "answer", role: .assistant, text: PreviewData.assistantMarkdown),
                decoration: MessageDecoration(showsActions: true))
            }
            .readingColumn()
            ComposerView(
              draft: .constant(""), state: PreviewData.idleSessionComposer,
              actions: ComposerActions(send: {}))
          }.padding(.vertical, Theme.Spacing.extraLarge).omnigentTheme(.omni).themeCanvas())
      },
      Surface(name: "sessions", regular: CGSize(width: 300, height: 860), compactHeight: 844) {
        AnyView(GallerySessionList())
      },
      Surface(name: "new-session", regular: CGSize(width: 560, height: 760), compactHeight: 844) {
        AnyView(GalleryNewSession())
      },
      Surface(name: "landing", regular: CGSize(width: 1_024, height: 768), compactHeight: 600) {
        AnyView(
          NewSessionPage(
            draft: .constant(""), composer: PreviewData.startComposer,
            actions: ComposerActions(send: {})))
      },
      Surface(name: "inspector", regular: CGSize(width: 340, height: 1_560), compactHeight: nil) {
        AnyView(GalleryPageContent(page: .inspector))
      },
      Surface(
        name: "inspector-open-files", regular: CGSize(width: 340, height: 600), compactHeight: nil
      ) {
        AnyView(
          WorkspaceInspector(
            state: PreviewData.shellConversation, actions: ConversationActions(),
            slots: WorkspaceSlots(
              documents: InspectorDocuments(
                tabs: [
                  InspectorDocumentTab(
                    id: "file:README.md", title: "README.md", detail: "README.md",
                    systemImage: "doc.text"),
                  InspectorDocumentTab(
                    id: "diff:src/main.rs", title: "main.rs", detail: "src/main.rs",
                    systemImage: "plus.forwardslash.minus"),
                ],
                selected: "diff:src/main.rs", select: { _ in }, close: { _ in }, showPanel: {},
                content: AnyView(Text("fn main() {}").monospaced())),
              openNew: {
                [
                  InspectorMenuSection(
                    id: "new",
                    items: [
                      InspectorMenuItem(id: "shell", title: "Shell", systemImage: "terminal") {}
                    ])
                ]
              }),
            tab: .constant(.files), maximized: .constant(false)))
      },
      Surface(
        name: "inspector-pull-requests", regular: CGSize(width: 340, height: 600),
        compactHeight: nil
      ) {
        AnyView(
          WorkspaceInspector(
            state: PreviewData.shellConversation, actions: ConversationActions(),
            slots: WorkspaceSlots(
              pullRequests: .loaded(PreviewData.pullRequests, synced: true)),
            tab: .constant(.pullRequests)))
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

    @Test("long permission labels wrap within a compact column")
    func wrappingLabels() throws {
      var measured = CGSize.zero
      let content = FlowLayout {
        Text("Approve and allow all directories in this workspace for the rest of this session")
          .font(.title)
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGSize.self) {
            $0.size
          } action: {
            measured = $0
          }
        Text("Reject")
      }
      _ = try RenderSupport.render(content, width: 280, scheme: .light, layout: .compact)
      #expect(measured.width <= 280)
      #expect(measured.height > 40)
    }

    @Test("conversation surfaces support every theme and accessibility sizing")
    func accessibleThemes() throws {
      for theme in OmnigentTheme.builtIn + [CustomTheme.default.theme()] {
        for scheme in [ColorScheme.light, .dark] {
          let content = VStack(spacing: Theme.Spacing.extraLarge) {
            MarkdownView(
              "A readable reply.\n\n```swift\nlet message = \"A longer code line that wraps inside a compact conversation\"\n```"
            )
            .padding(.horizontal, Theme.Spacing.compactGutter)
            DecisionCardView(card: PreviewData.codexCommand, respond: { _ in })
              .padding(.horizontal, Theme.Spacing.compactGutter)
            ComposerView(
              draft: .constant("A draft with\nseveral lines"), state: PreviewData.sessionComposer,
              actions: ComposerActions(send: {}))
          }
          .omnigentTheme(theme)
          .environment(\.dynamicTypeSize, .accessibility3)
          .themeCanvas()
          let rendered = try RenderSupport.render(
            content, width: 390, scheme: scheme, layout: .compact, increasedContrast: true)
          #expect(RenderSupport.inkCoverage(rendered) > 0.01)
          try RenderSupport.write(rendered, name: "ui-accessible-\(theme.id)-\(scheme)")
        }
      }
    }

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
