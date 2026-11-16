#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  private struct SandboxToolbarHost: View {
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

  /// The sandbox control among the conversation's real toolbar items, in a window with a
  /// titlebar.
  @Suite("Conversation toolbar: sandbox status", .serialized)
  @MainActor
  struct SandboxToolbarTests {
    private let log = HostLog()

    init() {
      SystemSideEffects.reset()
    }

    private func titled(_ sandbox: SandboxStatusState?) async throws -> OffscreenWindow<AnyView> {
      var state = ConversationViewState(
        header: TranscriptFixture.header, rows: [TranscriptFixture.answer("a")])
      state.summary = SessionSummary(id: "session-1", title: "A session")
      state.sandbox = sandbox
      let extras = ConversationExtras(sandbox: SandboxFixture.actions(log))
      let screen = transcriptScreen(
        SandboxToolbarHost(state: state, extras: extras), width: 1_100, height: 700)
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

    /// The accessibility identifiers under `root`, itself included.
    private func identifiers(under root: NSObject) -> Set<String> {
      var found: Set<String> = []
      var pending: [Any] = [root]
      while let next = pending.popLast() {
        guard let element = next as? NSObject else { continue }
        if element.responds(to: NSSelectorFromString("accessibilityIdentifier")),
          let identifier = element.value(forKey: "accessibilityIdentifier") as? String
        {
          found.insert(identifier)
        }
        if element.responds(to: NSSelectorFromString("accessibilityChildren")) {
          pending.append(contentsOf: element.value(forKey: "accessibilityChildren") as? [Any] ?? [])
        }
      }
      return found
    }

    /// The shown toolbar item holding the sandbox control, and every identifier it exposes.
    private func sandboxItem(
      _ screen: OffscreenWindow<AnyView>
    ) throws -> (view: NSView, identifiers: Set<String>)? {
      try screen.withAccessibilityTree {
        for item in screen.window.toolbar?.items ?? [] where item.isVisible {
          guard let view = item.view else { continue }
          let found = identifiers(under: view)
          if found.contains("header-sandbox") { return (view, found) }
        }
        return nil
      }
    }

    @Test("A sandbox session's titlebar shows the control with its mark; a click opens the panel")
    func shown() async throws {
      var sandbox = SandboxFixture.state(.resting, "Asleep")
      sandbox.hint = "The next message wakes it."
      let screen = try await titled(sandbox)
      defer { screen.close() }
      let item = try #require(try sandboxItem(screen), "the toolbar has no sandbox control")
      #expect(item.identifiers.contains("sandbox-mark-resting"))
      #expect(screen.popoverWindow == nil)
      try screen.click(item.view)
      #expect(await screen.waitUntil { screen.popoverWindow != nil })
      let panel = try #require(screen.popoverWindow?.contentView)
      let shown = try screen.shownText(under: panel)
      for text in ["Modal Sandbox", "Asleep", "The next message wakes it.", "Wake", "Stop Agent"] {
        #expect(shown.contains { $0.contains(text) }, "\(text) in \(shown)")
      }
    }

    @Test("A session without a sandbox has no sandbox control at all")
    func absent() async throws {
      let screen = try await titled(nil)
      defer { screen.close() }
      #expect(try sandboxItem(screen) == nil)
    }
  }
#endif
