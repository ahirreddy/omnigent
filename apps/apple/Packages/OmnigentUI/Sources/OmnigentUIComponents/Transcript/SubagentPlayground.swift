import SwiftUI

/// Stateful sample sub-agents: answering the blocked child's request from the parent sets it
/// running again, and opening a child shows its transcript with the route back.
struct SubagentPlayground: View {
  @State private var parent = PreviewData.subagentConversation
  @State private var child: ConversationViewState?
  @State private var draft = ""
  @State private var showsInspector = false

  var body: some View {
    NavigationStack {
      if let child {
        screen(child)
      } else {
        screen(parent)
      }
    }
  }

  private func screen(_ state: ConversationViewState) -> some View {
    var actions = ConversationActions(
      openSession: { id in open(id) },
      respond: { card, response in respond(card, response) },
      validateForm: PreviewData.validate)
    actions.openChild = { id in open(id) }
    return ConversationScreen(
      state: state, composer: PreviewData.sessionComposer, draft: $draft,
      showsInspector: $showsInspector, actions: actions,
      composerActions: ComposerActions(send: { draft = "" }))
  }

  private func open(_ id: String) {
    if id == parent.header.id {
      child = nil
      return
    }
    guard let section = parent.sections.first(where: { $0.sessionId == id }) else { return }
    var state = PreviewData.childConversation
    state.header.id = id
    state.header.title = section.title
    child = state
  }

  private func respond(_ card: DecisionCard, _ response: DecisionResponse) {
    parent.decisionPhases[card.id] = .answered(summary: response.summary)
    if let index = parent.sections.firstIndex(where: { $0.sessionId == card.targetSessionId }) {
      let section = parent.sections[index]
      parent.sections[index] = PreviewData.childSection(
        card.targetSessionId, title: section.title, state: .running, agent: "Codex",
        goal: section.details.first { $0.id == "goal" }?.text,
        activity: "Running the migration check", startedAgo: 150)
    }
    parent.revision += 1
  }
}

/// The iPhone reading posture: output keeps streaming while the user reads earlier rows (their
/// position holds and "Jump to latest" appears), and each session keeps its own draft.
struct PhoneReadingPlayground: View {
  @State private var sessions = PhoneReadingSamples.sessions
  @State private var selectedID = PhoneReadingSamples.sessions[0].header.id
  @State private var drafts: [String: String] = PhoneReadingSamples.drafts
  @State private var isStreaming = true
  @State private var showsInspector = false

  private var index: Int { sessions.firstIndex { $0.header.id == selectedID } ?? 0 }

  var body: some View {
    HStack {
      Spacer(minLength: 0)
      NavigationStack {
        ConversationScreen(
          state: sessions[index], composer: PreviewData.sessionComposer,
          draft: Binding(
            get: { drafts[selectedID, default: ""] }, set: { drafts[selectedID] = $0 }),
          showsInspector: $showsInspector, actions: ConversationActions(),
          composerActions: ComposerActions(send: { drafts[selectedID] = "" })
        )
        .id(selectedID)
        .toolbar {
          ToolbarItem(placement: .navigation) {
            Picker("Session", selection: $selectedID) {
              ForEach(sessions, id: \.header.id) { Text($0.header.title).tag($0.header.id) }
            }
            .accessibilityIdentifier("phone-reading-session")
          }
          ToolbarItem {
            Toggle("Stream", isOn: $isStreaming)
              .accessibilityIdentifier("phone-reading-stream")
          }
        }
      }
      .layoutWidth(.compact)
      .environment(\.horizontalSizeClass, .compact)
      .frame(width: 390)
      .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 36, style: .continuous)
          .strokeBorder(.separator, lineWidth: 2)
      }
      .padding(24)
      Spacer(minLength: 0)
    }
    .background(.background.secondary)
    .task(id: isStreaming) { await stream() }
  }

  /// Appends output to the selected session every second while streaming is on.
  private func stream() async {
    while isStreaming {
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        // Cancelled: the toggle changed or the playground closed.
        return
      }
      let session = index
      let count = sessions[session].rows.count
      sessions[session].rows.append(
        Row(
          id: "phone-live-\(count)", role: .assistant,
          text: "Output \(count): checked \(count % 9 + 1) more files.", agent: "Codex"))
      sessions[session].revision += 1
    }
  }
}

enum PhoneReadingSamples {
  static var sessions: [ConversationViewState] {
    var running = PreviewData.largeConversation(count: 120)
    running.header = SessionHeader(id: "phone_a", title: "Refactor token refresh", status: .running)
    var other = PreviewData.conversation
    other.header = SessionHeader(id: "phone_b", title: "Release checklist")
    other.sections = []
    return [running, other]
  }

  static let drafts = ["phone_b": "Push to auth-refresh once the tests pass"]
}
