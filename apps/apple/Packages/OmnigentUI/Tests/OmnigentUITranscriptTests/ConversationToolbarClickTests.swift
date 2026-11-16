#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// What a conversation's toolbar acts on.
  @MainActor
  @Observable
  private final class ToolbarScreenModel {
    var state: ConversationViewState
    var mode = SessionViewMode.chat
    var showsInspector = false
    var draft = ""
    /// The window's titlebar holds the tabs, so the session menu is a toolbar button.
    var tabsInTitlebar = false

    init(_ state: ConversationViewState) {
      self.state = state
    }
  }

  private struct ToolbarScreenHost: View {
    @Bindable var model: ToolbarScreenModel
    let extras: ConversationExtras

    var body: some View {
      ConversationScreen(
        state: model.state, composer: ComposerViewState(), draft: ComposerDraft($model.draft),
        showsInspector: $model.showsInspector, mode: $model.mode,
        actions: ConversationActions(), composerActions: ComposerActions(send: {}),
        extras: extras
      ) {
        Text("the terminal surface")
      }
      .environment(\.tabsInTitlebar, model.tabsInTitlebar)
    }
  }

  extension OffscreenWindow {
    /// One line per toolbar item, for a failure to say what the toolbar held.
    fileprivate var toolbarDescription: String {
      let items = window.toolbar?.items ?? []
      let lines = items.map { item in
        let view = item.view
        let frame = view.map { $0.convert($0.bounds, to: nil) } ?? .zero
        let kind = view.map { String(describing: Swift.type(of: $0)) } ?? "none"
        return "[\(item.itemIdentifier.rawValue)] label=\(item.label) tip=\(item.toolTip ?? "") "
          + "shown=\(item.isVisible) view=\(kind) frame=\(frame)"
      }
      return "toolbar: \(lines.joined(separator: " | "))"
    }

    /// The shown toolbar item named `name` by its label, its tooltip or the text it draws.
    fileprivate func toolbarView(named name: String) throws -> NSView? {
      for item in window.toolbar?.items ?? [] where item.isVisible {
        guard let view = item.view else { continue }
        if item.label == name || item.toolTip == name { return view }
        if try shownText(under: view).contains(name) { return view }
      }
      return nil
    }

    /// The middle of a toolbar item's view, from the top left of the content view.
    fileprivate func center(of view: NSView) -> CGPoint {
      let frame = view.convert(view.bounds, to: host)
      return CGPoint(x: frame.midX, y: frame.midY)
    }
  }

  /// The conversation's real toolbar items, in a window with a titlebar, taking real clicks.
  @Suite("Conversation toolbar: clicks", .serialized)
  @MainActor
  struct ConversationToolbarClickTests {
    private let log = HostLog()

    init() {
      SystemSideEffects.reset()
    }

    private func conversation() -> ConversationViewState {
      var state = ConversationViewState(
        header: TranscriptFixture.header, rows: [TranscriptFixture.answer("a")])
      state.summary = SessionSummary(id: "session-1", title: "A session")
      return state
    }

    private var sharing: ConversationExtras {
      let log = self.log
      return ConversationExtras(
        share: (state: ShareViewState(), actions: ShareActions()),
        shareOpened: { log.add("share opened") })
    }

    /// A window with a titlebar, so the screen's toolbar has somewhere to go.
    private func titled(
      _ model: ToolbarScreenModel, extras: ConversationExtras = ConversationExtras()
    ) async throws -> OffscreenWindow<AnyView> {
      let screen = transcriptScreen(
        ToolbarScreenHost(model: model, extras: extras), width: 1_100, height: 700)
      screen.window.contentView = nil
      screen.window.styleMask = [.titled, .resizable, .fullSizeContentView]
      screen.host.sceneBridgingOptions = [.toolbars, .title]
      screen.window.contentView = screen.host
      let hasItems = await screen.waitUntil { screen.window.toolbar?.items.isEmpty == false }
      try #require(hasItems, "the window has no toolbar items")
      // The toolbar places its items in the first layout pass after the window has them.
      screen.window.setContentSize(CGSize(width: 1_100, height: 701))
      let arePlaced = await screen.waitUntil {
        screen.window.toolbar?.items.contains(where: \.isVisible) == true
      }
      try #require(arePlaced, "\(screen.toolbarDescription)")
      screen.settle(0.3)
      return screen
    }

    @Test("Share in the toolbar opens the share sheet and tells the host to read the grants")
    func shareButton() async throws {
      let screen = try await titled(ToolbarScreenModel(conversation()), extras: sharing)
      defer { screen.close() }
      let share = try #require(
        try screen.toolbarView(named: "Share"), "\(screen.toolbarDescription)")
      #expect(screen.window.attachedSheet == nil)
      try screen.click(share)
      #expect(
        await screen.waitUntil { screen.window.attachedSheet != nil },
        "\(screen.toolbarDescription)")
      #expect(log.entries == ["share opened"])
    }

    @Test("A session that can't be shared keeps Share off")
    func shareButtonUnavailable() async throws {
      var state = conversation()
      state.shareUnavailableReason = "Only the owner can share this session."
      let screen = try await titled(ToolbarScreenModel(state), extras: sharing)
      defer { screen.close() }
      let share = try #require(
        try screen.toolbarView(named: "Share"), "\(screen.toolbarDescription)")
      try screen.click(share)
      try await letTasksRun(screen, milliseconds: 200)
      #expect(screen.window.attachedSheet == nil)
      #expect(log.entries.isEmpty)
    }

    @Test("Agent info in the toolbar opens what the agent has, and closes it at a second click")
    func agentInfoButton() async throws {
      var state = conversation()
      state.agentInfo = AgentInfo(name: "Otto", tools: ["Bash"], policies: ["No main"])
      let screen = try await titled(ToolbarScreenModel(state))
      defer { screen.close() }
      let info = try #require(
        try screen.toolbarView(named: "Agent info"), "\(screen.toolbarDescription)")
      #expect(screen.popoverWindow == nil)
      try screen.click(info)
      #expect(
        await screen.waitUntil { screen.popoverWindow != nil },
        "\(screen.toolbarDescription)")
      let popover = try #require(screen.popoverWindow?.contentView)
      let shown = try screen.shownText(under: popover)
      for text in ["Otto", "Bash", "No main"] {
        #expect(shown.contains { $0.contains(text) }, "\(text) in \(shown)")
      }
      try screen.click(info)
      #expect(await screen.waitUntil { screen.popoverWindow == nil })
    }

    @Test("Beside the tabs, the session menu's Share opens the same sheet")
    func sessionMenuShare() async throws {
      let model = ToolbarScreenModel(conversation())
      model.tabsInTitlebar = true
      let screen = try await titled(model, extras: sharing)
      defer { screen.close() }
      let button = try #require(
        try screen.toolbarView(named: "Session") ?? screen.toolbarView(named: "Session actions"),
        "\(screen.toolbarDescription)")
      let menu = try screen.openMenu(screen.center(of: button))
      try screen.choose("Share", in: menu)
      #expect(
        await screen.waitUntil { screen.window.attachedSheet != nil },
        "\(menuTitles(menu))")
      #expect(log.entries == ["share opened"])
    }
  }
#endif
