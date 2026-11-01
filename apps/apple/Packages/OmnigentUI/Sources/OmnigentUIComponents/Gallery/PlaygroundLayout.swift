public import SwiftUI

/// The full app with sample data: the web-structured shell (sidebar and detail), the session
/// page with its right panel, the new-session page, the Inbox and Canvas, plus the server
/// settings, theme gallery and component gallery. Used by the playground app and the previews.
public struct PlaygroundView: View {
  @Bindable private var model: PlaygroundModel
  private let slots: WorkspaceSlots

  /// Creates the view.
  /// - Parameters:
  ///   - model: The playground state.
  ///   - slots: Files and Changes content for the right panel.
  public init(model: PlaygroundModel, slots: WorkspaceSlots = WorkspaceSlots()) {
    self.model = model
    self.slots = slots
  }

  /// The layout for the model's scenario.
  public var body: some View {
    Group {
      switch model.scenario {
      case .gallery:
        UIGalleryView()
      case .themes:
        ThemeGalleryView()
      case .serverSettings:
        ServerSettingsView(
          state: PreviewData.serverSettings, selectedServer: .constant("dbx"),
          actions: ServerSettingsActions())
      case .compact:
        compactLayout
      case .streaming, .terminal, .approvals, .longTranscript, .newSession, .inbox, .empty, .errors:
        shell
      }
    }
    .omnigentTheme(model.preferences.theme, appearance: model.preferences.mode)
  }

  private var importSessions: @MainActor () -> Void { {} }

  private var shell: some View {
    AppShell(
      sidebar: model.sidebar, selection: $model.selection, searchText: $model.search,
      actions: model.sidebarActions
    ) { destination in
      detail(destination)
    }
  }

  @ViewBuilder
  private func detail(_ destination: SidebarDestination?) -> some View {
    switch destination {
    case .newSession, nil:
      NewSessionPage(
        draft: $model.startDraft, composer: model.startComposer, actions: model.startActions,
        importSessions: model.sidebar.list.sessions.isEmpty ? importSessions : nil)
    case .inbox:
      InboxView(state: model.inbox, actions: model.inboxActions)
    case .canvas:
      CanvasView(sessions: model.sidebar.list.sessions) { id in model.selection = .session(id) }
    case .session:
      conversation
    }
  }

  private var conversation: some View {
    ConversationScreen(
      state: model.conversation, composer: model.composer, draft: $model.draft,
      showsInspector: $model.showsInspector, inspectorTab: $model.inspectorTab, mode: $model.mode,
      fork: $model.fork, actions: model.conversationActions,
      composerActions: model.composerActions,
      extras: ConversationExtras(
        sessionActions: model.sidebarActions.sessions, slots: slots,
        share: (model.share, model.shareActions), forkActions: model.forkActions)
    ) {
      TerminalPlaceholderView(harness: model.conversation.header.settings?.harness)
    }
  }

  private var compactLayout: some View {
    HStack {
      Spacer(minLength: 0)
      NavigationStack {
        conversation
      }
      .layoutWidth(.compact)
      .environment(\.horizontalSizeClass, .compact)
      .frame(width: 390)
      .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 36, style: .continuous).strokeBorder(
          .separator, lineWidth: 2)
      }
      .padding(24)
      Spacer(minLength: 0)
    }
    .background(.background.secondary)
  }
}

/// Every built-in theme side by side, light and dark: sidebar tint, canvas, accent, brand
/// accent, link and status samples.
public struct ThemeGalleryView: View {
  /// Creates the gallery.
  public init() {}

  /// The gallery.
  public var body: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
        ForEach(OmnigentTheme.builtIn + [CustomTheme.default.theme()]) { theme in
          VStack(alignment: .leading, spacing: 6) {
            Text(theme.name).font(.headline)
            Text(theme.blurb).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
              ThemeSample(theme: theme).environment(\.colorScheme, .light)
              ThemeSample(theme: theme).environment(\.colorScheme, .dark)
            }
          }
        }
      }
      .padding(20)
    }
    .navigationTitle("Themes")
  }
}

private struct ThemeSample: View {
  let theme: OmnigentTheme

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Label("New session", systemImage: "plus.bubble").font(.caption)
        HStack {
          Text("Session").font(.caption)
          Spacer()
          Circle().fill(Theme.brandAccent).frame(width: 6, height: 6)
        }
        Text("Needs response")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(Theme.brandAccent)
          .padding(.horizontal, 5)
          .background(Theme.brandAccent.opacity(0.15), in: Capsule())
      }
      .padding(8)
      .frame(width: 110, alignment: .topLeading)
      .frame(maxHeight: .infinity, alignment: .top)
      .themeSidebar()
      VStack(alignment: .leading, spacing: 6) {
        Text("Worked for 1m 46s").font(.caption).foregroundStyle(.secondary)
        Text("Links look like this.").font(.caption).foregroundStyle(Theme.link)
        HStack(spacing: 4) {
          Button("Share") {}.buttonStyle(.borderedProminent).controlSize(.small)
          Circle().fill(Theme.success).frame(width: 7, height: 7)
          Circle().fill(Theme.warning).frame(width: 7, height: 7)
          Circle().fill(Theme.failure).frame(width: 7, height: 7)
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .themeCanvas()
    }
    .frame(height: 110)
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
    .overlay { RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(.separator) }
    .omnigentTheme(theme)
  }
}
