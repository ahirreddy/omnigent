public import SwiftUI

/// A debug gallery of every component with sample data: the full app layout, the transcript
/// with every row kind, every decision kind, the composer states, the session list, the
/// new-session sheet, the inspector, markdown and a 3,000-row transcript. A toolbar toggle
/// previews compact width.
public struct UIGalleryView: View {
  @State private var page: GalleryPage? = .app
  @State private var compact = false
  @State private var scheme: ColorScheme?

  /// Creates the gallery.
  public init() {}

  /// The gallery.
  public var body: some View {
    NavigationSplitView {
      List(GalleryPage.allCases, selection: $page) { page in
        Label(page.title, systemImage: page.systemImage).tag(page)
      }
      .navigationTitle("UI Gallery")
      .navigationSplitViewColumnWidth(min: 180, ideal: 210)
    } detail: {
      Group {
        if let page {
          GalleryPageView(page: page, layout: compact ? .compact : .regular)
            .frame(maxWidth: compact ? 390 : .infinity)
            .environment(\.horizontalSizeClass, compact ? .compact : .regular)
        } else {
          ContentUnavailableView("Choose a Page", systemImage: "square.grid.2x2")
        }
      }
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          Toggle(isOn: $compact) {
            Label("Compact Width", systemImage: "iphone")
          }
          .help("Preview compact width (iPhone, folded Duo)")
          Picker("Appearance", selection: $scheme) {
            Text("System").tag(ColorScheme?.none)
            Text("Light").tag(ColorScheme?.some(.light))
            Text("Dark").tag(ColorScheme?.some(.dark))
          }
          .pickerStyle(.menu)
          .fixedSize()
        }
      }
    }
    .preferredColorScheme(scheme)
  }
}

/// The gallery's pages.
enum GalleryPage: String, CaseIterable, Identifiable, Hashable {
  case app
  case transcript
  case decisions
  case composer
  case sessionList
  case newSession
  case inspector
  case markdown
  case large

  var id: Self { self }

  var title: String {
    switch self {
    case .app: "App Layout"
    case .transcript: "Transcript"
    case .decisions: "Decisions"
    case .composer: "Composer"
    case .sessionList: "Session List"
    case .newSession: "New Session"
    case .inspector: "Inspector"
    case .markdown: "Markdown"
    case .large: "3,000 Rows"
    }
  }

  var systemImage: String {
    switch self {
    case .app: "macwindow"
    case .transcript: "text.bubble"
    case .decisions: "hand.raised"
    case .composer: "square.and.pencil"
    case .sessionList: "sidebar.left"
    case .newSession: "plus.square"
    case .inspector: "sidebar.right"
    case .markdown: "textformat"
    case .large: "speedometer"
    }
  }
}

/// One gallery page, scrollable in the app.
struct GalleryPageView: View {
  let page: GalleryPage
  let layout: LayoutWidth

  var body: some View {
    Group {
      switch page {
      case .app:
        GalleryAppLayout()
      case .sessionList:
        GallerySessionList()
      case .newSession:
        GalleryNewSession()
      case .large:
        GalleryConversation(state: PreviewData.largeConversation(count: 3_000))
      case .transcript, .decisions, .composer, .inspector, .markdown:
        ScrollView {
          GalleryPageContent(page: page)
            .padding(layout == .compact ? 12 : 24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
      }
    }
    .layoutWidth(layout)
  }
}

/// The unscrolled content of the static pages, also rendered whole by the rendering tests.
struct GalleryPageContent: View {
  let page: GalleryPage

  var body: some View {
    switch page {
    case .transcript: GalleryTranscript()
    case .decisions: GalleryDecisions()
    case .composer: GalleryComposer()
    case .inspector:
      SessionInspectorView(state: PreviewData.conversation, actions: GalleryActions.conversation)
        .frame(height: 1_560)
    case .markdown:
      MarkdownView(PreviewData.assistantMarkdown)
    case .app, .sessionList, .newSession, .large:
      EmptyView()
    }
  }
}

/// Every transcript item laid out eagerly (the real ``TranscriptView`` is lazy).
struct GalleryTranscript: View {
  var state = PreviewData.conversation

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.row) {
      SessionHeaderView(state: state)
      ForEach(TranscriptView.entries(for: state.rows)) { entry in
        switch entry.item {
        case .message(let row): MessageRowView(row: row, showsAuthor: entry.showsAuthor)
        case .tools(_, let entries): ToolGroupView(entries: entries)
        case .activity(let row): ActivityRowView(row: row)
        }
      }
      ChildSessionsStrip(sections: state.sections, currentSessionID: state.header.id)
      ErrorBanner(
        message: "Lost connection to the server. Reconnecting in 4 seconds.", dismiss: {}, retry: {}
      )
      PlanAccordion(section: PreviewData.sections[3])
    }
    .environment(\.conversationActions, GalleryActions.conversation)
  }
}

struct GalleryDecisions: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      ForEach(PreviewData.decisions) { card in
        DecisionCardView(
          card: card, phase: card.answered ? .answered(summary: "Approved") : .pending,
          respond: { _ in }, validate: { PreviewData.validate(card, $0) })
      }
      GallerySection("Sending") {
        DecisionCardView(card: PreviewData.choice, phase: .resolving, respond: { _ in })
      }
      GallerySection("Send failed") {
        DecisionCardView(
          card: PreviewData.approval,
          phase: .failed(
            message: "Could not send your response: the server returned 503. Try again."),
          respond: { _ in })
      }
      GallerySection("Read only") {
        DecisionCardView(card: PreviewData.codexCommand, isReadOnly: true, respond: nil)
      }
    }
  }
}

struct GalleryComposer: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      ForEach(PreviewData.composerStates) { sample in
        GallerySection(sample.title) {
          ComposerView(
            draft: .constant(sample.draft), state: sample.state, actions: GalleryActions.composer)
        }
      }
    }
  }
}

private struct GallerySection<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
      content
    }
  }
}

struct GallerySessionList: View {
  @State private var selection: String? = PreviewData.sessionID
  @State private var search = ""
  @State private var filter: SessionFilter = .all

  var body: some View {
    NavigationStack {
      SessionListView(
        state: {
          var state = PreviewData.sessionList
          state.filter = filter
          return state
        }(),
        selection: $selection, searchText: $search,
        actions: GalleryActions.sessionList(filter: $filter))
    }
  }
}

struct GalleryNewSession: View {
  @State private var phase = 0

  var body: some View {
    NewSessionView(
      state: PreviewData.newSession,
      actions: NewSessionActions(
        unavailableReason: PreviewData.unavailableReason, create: { _, _, _ in }, cancel: {}),
      initialSelection: CreationSelection(hostId: "host_mbp", agentId: "agent_codex"))
  }
}

struct GalleryConversation: View {
  let state: ConversationViewState
  var composer = PreviewData.composerRunning
  @State private var draft = ""
  @State private var showsInspector = false

  var body: some View {
    NavigationStack {
      ConversationScreen(
        state: state, composer: composer, draft: $draft, showsInspector: $showsInspector,
        actions: GalleryActions.conversation, composerActions: GalleryActions.composer)
    }
  }
}

struct GalleryAppLayout: View {
  /// Lays the inspector out as a plain column (for offscreen rendering, where the system
  /// inspector presentation does not draw).
  var inlineInspector = false
  @State private var selection: String? = PreviewData.sessionID
  @State private var search = ""
  @State private var filter: SessionFilter = .all
  @State private var draft = "Also cover the 401 path."
  @State private var showsInspector = true
  @Environment(\.layoutWidth) private var layoutWidth

  var body: some View {
    if layoutWidth == .compact {
      GalleryConversation(state: PreviewData.conversation)
    } else {
      HStack(spacing: 0) {
        SessionListView(
          state: PreviewData.sessionList, selection: $selection, searchText: $search,
          actions: GalleryActions.sessionList(filter: $filter)
        )
        .frame(width: 290)
        Divider()
        NavigationStack {
          ConversationScreen(
            state: PreviewData.conversation, composer: PreviewData.composerRunning, draft: $draft,
            showsInspector: inlineInspector ? .constant(false) : $showsInspector,
            actions: GalleryActions.conversation, composerActions: GalleryActions.composer)
        }
        if inlineInspector {
          Divider()
          SessionInspectorView(
            state: PreviewData.conversation, actions: GalleryActions.conversation
          )
          .frame(width: 300)
        }
      }
    }
  }
}

/// No-op actions for the gallery and previews.
enum GalleryActions {
  static let conversation = ConversationActions(
    loadOlder: {}, openSession: { _ in }, openAttachment: { _ in }, openURL: { _ in },
    respond: { _, _ in }, validateForm: PreviewData.validate, dismissError: {}, retry: {})

  static let composer = ComposerActions(
    send: {}, interrupt: {}, addAttachments: { _ in }, removeAttachment: { _ in },
    selectModel: { _ in }, selectEffort: { _ in }, selectAgent: { _ in },
    acknowledgeUncertainDelivery: {}, dismissDeliveryError: {})

  static func sessionList(filter: Binding<SessionFilter>) -> SessionListActions {
    SessionListActions(
      setFilter: { filter.wrappedValue = $0 }, setPinned: { _, _ in }, setArchived: { _, _ in },
      rename: { _, _ in }, setUnread: { _, _ in }, openInNewWindow: { _ in },
      webURL: { URL(string: "https://omnigent.example.com/c/\($0.id)") }, newSession: {})
  }
}

#Preview("Gallery") {
  UIGalleryView()
}

#Preview("Transcript") {
  ScrollView { GalleryTranscript().padding() }
    .frame(width: 760, height: 900)
}

#Preview("Decisions") {
  ScrollView { GalleryDecisions().padding() }
    .frame(width: 700, height: 900)
}

#Preview("Composer") {
  ScrollView { GalleryComposer().padding() }
    .frame(width: 700, height: 800)
}

#Preview("Session list") {
  GallerySessionList().frame(width: 300, height: 700)
}

#Preview("Conversation, compact") {
  GalleryConversation(state: PreviewData.conversation)
    .layoutWidth(.compact)
    .frame(width: 390, height: 844)
}
