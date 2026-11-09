#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The CLI composer with a real draft, the way a screen hosts it.
  struct CLIComposerHost: View {
    let state: ComposerViewState
    let actions: ComposerActions
    let layoutStyle: ComposerLayoutStyle
    let preferences: TranscriptPreferences
    @State private var draft: String

    init(
      state: ComposerViewState, actions: ComposerActions, layoutStyle: ComposerLayoutStyle,
      preferences: TranscriptPreferences, draft: String
    ) {
      self.state = state
      self.actions = actions
      self.layoutStyle = layoutStyle
      self.preferences = preferences
      _draft = State(initialValue: draft)
    }

    var body: some View {
      CLIComposer(draft: $draft, state: state, actions: actions)
        .environment(\.composerLayoutStyle, layoutStyle)
        .transcriptAppearance(preferences.appearance(style: .cli))
    }
  }

  /// Hosts the CLI composer off screen with its own preferences.
  @MainActor
  func cliComposerScreen(
    _ state: ComposerViewState, actions: ComposerActions, layoutStyle: ComposerLayoutStyle = .card,
    layout: LayoutWidth = .regular, draft: String = "", width: CGFloat = 800
  ) throws -> OffscreenWindow<AnyView> {
    let defaults = try #require(UserDefaults(suiteName: "cli-composer-\(UUID().uuidString)"))
    return transcriptScreen(
      CLIComposerHost(
        state: state, actions: actions, layoutStyle: layoutStyle,
        preferences: TranscriptPreferences(defaults: defaults), draft: draft),
      width: width, height: 300, layout: layout)
  }

  @MainActor
  @Observable
  private final class FocusRequests {
    var count = 0
    var isHidden = false
  }

  /// A composer whose focus requests and tab visibility a test changes from outside.
  private struct FocusRequestHost: View {
    let requests: FocusRequests

    var body: some View {
      CLIComposer(
        draft: .constant(""), state: ComposerViewState(), actions: ComposerActions(send: {}),
        focusRequest: requests.count
      )
      .environment(\.isTabContentHidden, requests.isHidden)
    }
  }

  @Suite("CLI composer", .serialized)
  @MainActor
  struct TranscriptCLIComposerTests {
    private let log = HostLog()

    init() {
      SystemSideEffects.reset()
    }

    private func composer(
      _ state: ComposerViewState = ComposerViewState(), actions: ComposerActions? = nil,
      layoutStyle: ComposerLayoutStyle = .card, layout: LayoutWidth = .regular,
      draft: String = "", width: CGFloat = 800
    ) throws -> OffscreenWindow<AnyView> {
      let log = self.log
      return try cliComposerScreen(
        state, actions: actions ?? ComposerActions(send: { log.add("send") }),
        layoutStyle: layoutStyle, layout: layout, draft: draft, width: width)
    }

    private func editor(on screen: OffscreenWindow<AnyView>) throws -> NSTextView {
      try #require(screen.allViews.compactMap { $0 as? NSTextView }.first)
    }

    // MARK: Typing and sending

    @Test("The placeholder gives way to typing, and Return sends what was typed")
    func typeAndSend() async throws {
      let screen = try composer(ComposerViewState(placeholder: "Ask anything"))
      defer { screen.close() }
      #expect(try screen.shows("Ask anything"))
      try await letTasksRun(screen, milliseconds: 200)
      #expect(screen.window.firstResponder is NSTextView)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(log.entries.isEmpty)
      try screen.type("hello")
      #expect(try !screen.shows("Ask anything"))
      #expect(try editor(on: screen).string == "hello")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(log.entries == ["send"])
    }

    @Test("The controls appear on hover or focus; Send sends")
    func hoverControls() throws {
      let screen = try composer(draft: "ready")
      defer { screen.close() }
      let idle = screen.controlFrames.count
      let band = try editor(on: screen).convert(try editor(on: screen).bounds, to: screen.host)
      try screen.hover(CGPoint(x: band.midX, y: band.midY))
      screen.settle()
      let revealed = screen.controlFrames
      #expect(revealed.count > idle)
      let send = try #require(revealed.last)
      try screen.click(CGPoint(x: send.midX, y: send.midY))
      #expect(log.entries == ["send"])
      try screen.endHover()
      screen.settle()
      #expect(screen.controlFrames.count == idle)
    }

    @Test("Touch always shows its controls")
    func touchControls() throws {
      let screen = try composer(layoutStyle: .touch, draft: "ready")
      defer { screen.close() }
      let send = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: send.midX, y: send.midY))
      #expect(log.entries == ["send"])
    }

    @Test("A session that can't send doesn't send, whatever is typed")
    func unavailableDoesNotSend() async throws {
      let screen = try composer(ComposerViewState(availability: .unavailable(reason: "Offline")))
      defer { screen.close() }
      try await letTasksRun(screen, milliseconds: 200)
      try screen.type("x")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(log.entries.isEmpty)
    }

    // A plain disabled TextEditor takes typing in this window too, so check it in a real app first.
    @Test(
      "A session that can't send doesn't take typing",
      .disabled("TextEditor keeps taking keys under .disabled here, in chat and CLI alike"))
    func unavailableEditorIsLocked() async throws {
      let screen = try composer(ComposerViewState(availability: .unavailable(reason: "Offline")))
      defer { screen.close() }
      try await letTasksRun(screen, milliseconds: 200)
      try screen.type("x")
      #expect(try editor(on: screen).string.isEmpty)
    }

    // MARK: Focus

    @Test("The composer takes the keyboard when it comes on screen")
    func focusOnShowing() async throws {
      let screen = try composer()
      defer { screen.close() }
      #expect(!(screen.window.firstResponder is NSTextView))
      try await letTasksRun(screen, milliseconds: 200)
      #expect(screen.window.firstResponder is NSTextView)
    }

    @Test("A composer in a hidden tab or an inactive pane leaves the keyboard alone")
    func noFocusWhenNotShowing() async throws {
      for (isHidden, isActive) in [(true, true), (false, false)] {
        let requests = FocusRequests()
        requests.isHidden = isHidden
        let screen = transcriptScreen(
          FocusRequestHost(requests: requests).environment(\.isActiveTabPane, isActive))
        defer { screen.close() }
        try await letTasksRun(screen, milliseconds: 200)
        #expect(!(screen.window.firstResponder is NSTextView), "\(isHidden) \(isActive)")
      }
    }

    @Test("A menu command focuses the editor even in an inactive pane")
    func focusRequest() async throws {
      let requests = FocusRequests()
      let screen = transcriptScreen(
        FocusRequestHost(requests: requests).environment(\.isActiveTabPane, false))
      defer { screen.close() }
      try await letTasksRun(screen, milliseconds: 200)
      #expect(!(screen.window.firstResponder is NSTextView))
      requests.count += 1
      try await letTasksRun(screen)
      #expect(screen.window.firstResponder is NSTextView)
    }

    @Test("A kept tab that leaves the screen gives up the keyboard")
    func hiddenTabGivesUpFocus() async throws {
      let requests = FocusRequests()
      let screen = transcriptScreen(FocusRequestHost(requests: requests))
      defer { screen.close() }
      try await letTasksRun(screen, milliseconds: 200)
      #expect(screen.window.firstResponder is NSTextView)
      requests.isHidden = true
      try await letTasksRun(screen)
      #expect(!(screen.window.firstResponder is NSTextView))
    }

    @Test("A read-only session on touch shows why instead of an editor")
    func readOnlyTouch() throws {
      var state = ComposerViewState(availability: .unavailable(reason: "Shared with you"))
      state.isReadOnly = true
      let touch = try composer(state, layoutStyle: .touch)
      defer { touch.close() }
      #expect(try touch.shows("Shared with you"))
      #expect(touch.allViews.compactMap { $0 as? NSTextView }.isEmpty)
      let card = try composer(state)
      defer { card.close() }
      #expect(!card.allViews.compactMap { $0 as? NSTextView }.isEmpty)
    }

    @Test("A failed send shows above the band and can be dismissed")
    func deliveryFailure() throws {
      let screen = try composer(
        ComposerViewState(delivery: .failed(message: "The server refused it")),
        actions: ComposerActions(
          send: {}, dismissDeliveryError: { [log] in log.add("dismissed") }))
      defer { screen.close() }
      #expect(try screen.shows("The server refused it"))
      try screen.clickControl(at: 1)
      #expect(log.entries == ["dismissed"])
    }

    @Test("Queued messages show above the band")
    func queue() throws {
      let screen = try composer(
        ComposerViewState(queue: [QueuedMessage(id: "q", text: "and then this")]))
      defer { screen.close() }
      #expect(try screen.shows("and then this"))
    }

    // MARK: Choosing the composer

    @Test("The screen's composer follows the style and reports when the draft gains text")
    func transcriptComposer() throws {
      let defaults = try #require(UserDefaults(suiteName: "cli-composer-\(UUID().uuidString)"))
      let preferences = TranscriptPreferences(defaults: defaults)
      var reported: [Bool] = []
      var text = "   "
      let draft = ComposerDraft(get: { text }, set: { text = $0 })
      func screen(_ style: TranscriptStyle) -> OffscreenWindow<AnyView> {
        transcriptScreen(
          TranscriptComposer(
            draft: draft, state: ComposerViewState(), actions: ComposerActions(send: {}),
            focusRequest: 0, hasTextChanged: { reported.append($0) }
          )
          .transcriptAppearance(preferences.appearance(style: style)), height: 300)
      }
      let cli = screen(.cli)
      defer { cli.close() }
      #expect(reported == [false])
      #expect(try cli.shows("\u{203A}"))
      let chat = screen(.chat)
      defer { chat.close() }
      #expect(try !chat.shows("\u{203A}"))
    }

    @Test("Only whitespace isn't something to send")
    func draftText() {
      #expect(ComposerDraftText.hasText(" hi "))
      #expect(!ComposerDraftText.hasText(" \n\t"))
      #expect(!ComposerDraftText.hasText(""))
    }
  }
#endif
