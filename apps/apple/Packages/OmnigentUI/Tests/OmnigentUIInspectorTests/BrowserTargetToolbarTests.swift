#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  private struct BrowserToolbarHost: View {
    let state: ConversationViewState
    let extras: ConversationExtras
    @State private var mode = SessionViewMode.chat
    @State private var showsInspector = false
    @State private var draft = ""

    var body: some View {
      ConversationScreen(
        state: state, composer: ComposerViewState(), draft: ComposerDraft($draft),
        showsInspector: $showsInspector, mode: $mode, actions: ConversationActions(),
        composerActions: ComposerActions(send: {}), extras: extras
      ) {
        Text("the terminal surface")
      }
    }
  }

  /// The browser chip among the conversation's real toolbar items, in a window with a titlebar.
  @Suite("Conversation toolbar: browser chip", .serialized)
  @MainActor
  struct BrowserTargetToolbarTests {
    init() {
      SystemSideEffects.reset()
    }

    private func titled(
      _ browser: BrowserTargetState?, offersChoice: Bool = true
    ) async throws -> OffscreenWindow<AnyView> {
      var state = ConversationViewState(
        header: TranscriptFixture.header, rows: [TranscriptFixture.answer("a")])
      state.summary = SessionSummary(id: "session-1", title: "A session")
      state.browserTarget = browser
      var extras = ConversationExtras()
      if offersChoice { extras.chooseBrowserTarget = { _ in } }
      let screen = transcriptScreen(
        BrowserToolbarHost(state: state, extras: extras), width: 1_100, height: 700)
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
      try #require(arePlaced, "no toolbar item was placed")
      screen.settle(0.3)
      return screen
    }

    /// What the shown chip says (its accessibility label, or a menu item's tooltip), or `nil`
    /// when the toolbar has none.
    private func chip(_ screen: OffscreenWindow<AnyView>) throws -> String? {
      try screen.withAccessibilityTree {
        for item in screen.window.toolbar?.items ?? [] where item.isVisible {
          if let view = item.view, let label = label(under: view) { return label }
          if item.view == nil, item.toolTip?.hasPrefix("Browser:") == true { return item.toolTip }
        }
        return nil
      }
    }

    /// The accessibility label of the chip under `root`.
    private func label(under root: NSObject) -> String? {
      var pending: [Any] = [root]
      while let next = pending.popLast() {
        guard let element = next as? NSObject else { continue }
        if element.responds(to: NSSelectorFromString("accessibilityIdentifier")),
          element.value(forKey: "accessibilityIdentifier") as? String == "header-browser-target"
        {
          return element.value(forKey: "accessibilityLabel") as? String ?? ""
        }
        if element.responds(to: NSSelectorFromString("accessibilityChildren")) {
          pending.append(contentsOf: element.value(forKey: "accessibilityChildren") as? [Any] ?? [])
        }
      }
      return nil
    }

    @Test("The chip names the current browser where the server offers the agent browser")
    func shown() async throws {
      let screen = try await titled(BrowserTargetState(choice: .remote))
      defer { screen.close() }
      let label = try #require(try chip(screen), "the toolbar has no browser chip")
      #expect(label.contains("Agent\u{2019}s machine"), "\(label)")
    }

    @Test("No chip without the agent browser or without a way to switch")
    func absent() async throws {
      let off = try await titled(nil)
      #expect(try chip(off) == nil)
      off.close()
      let readOnly = try await titled(BrowserTargetState(choice: .auto), offersChoice: false)
      #expect(try chip(readOnly) == nil)
      readOnly.close()
    }
  }
#endif
