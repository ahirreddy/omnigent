#if os(macOS)
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// A Claude session's row with its mark in `style`.
  struct HarnessActivityRow: View {
    let style: HarnessIconStyle
    var attention = SessionAttentionState.idle
    var hasLiveSandbox = false
    var isArchived = false

    var body: some View {
      let session = SessionSummary(
        id: "s", title: "Fix the build", updatedAt: 0, isArchived: isArchived,
        attention: attention)
      var info = SessionRowInfo(harness: "claude-native")
      info.hasLiveSandbox = hasLiveSandbox
      return SessionRow(
        session: session, info: info, isUnread: false, attention: 0, details: [],
        harnessIcon: style, now: Date(timeIntervalSince1970: 60),
        menu: SessionRowMenu(
          session: session, isUnread: false, isShared: false, pinLimitReached: false,
          projects: [], actions: SessionListActions(), rename: {}, confirmDelete: {},
          confirmLeave: {}, confirmStop: {}))
    }
  }

  /// Color while active: a mark in color while its session or sandbox is alive, in one color
  /// otherwise, and the new session's agent, which has no session yet.
  @Suite("Harness marks that follow a session's activity", .serialized)
  @MainActor
  struct HarnessIconActivityTests {
    /// Claude's orange.
    private let orange: UInt32 = 0xD97757

    @Test("Color while active picks color or one color; every other style stays as chosen")
    func resolved() {
      #expect(HarnessIconStyle.colorWhileActive.resolved(isActive: true) == .color)
      #expect(HarnessIconStyle.colorWhileActive.resolved(isActive: false) == .monochrome)
      for style in [HarnessIconStyle.color, .monochrome, .hidden] {
        #expect(style.resolved(isActive: true) == style, "\(style)")
        #expect(style.resolved(isActive: false) == style, "\(style)")
      }
    }

    @Test("A session is alive while a turn runs or waits on the user, or its sandbox is up")
    func activity() {
      func isActive(
        _ attention: SessionAttentionState, sandbox: Bool = false, archived: Bool = false
      ) -> Bool {
        var info = SessionRowInfo()
        info.hasLiveSandbox = sandbox
        return SessionRow.isActive(
          SessionSummary(id: "s", title: "T", isArchived: archived, attention: attention),
          info: info)
      }
      #expect(isActive(.working))
      #expect(isActive(.needsYou))
      for quiet in [SessionAttentionState.idle, .unread, .failed] {
        #expect(!isActive(quiet), "\(quiet)")
        #expect(isActive(quiet, sandbox: true), "\(quiet) with a live sandbox")
      }
      #expect(!isActive(.working, archived: true))
      #expect(!isActive(.needsYou, sandbox: true, archived: true))
    }

    @Test("A row draws color for a running session or a live sandbox, one color otherwise")
    func rowColors() throws {
      func shown(_ row: HarnessActivityRow) throws -> Bool {
        RenderSupport.shows(
          orange,
          in: try RenderSupport.render(
            row, width: 280, height: 32, scheme: .dark, layout: .regular))
      }
      #expect(try shown(HarnessActivityRow(style: .colorWhileActive, attention: .working)))
      #expect(try shown(HarnessActivityRow(style: .colorWhileActive, hasLiveSandbox: true)))
      #expect(try !shown(HarnessActivityRow(style: .colorWhileActive)))
      #expect(
        try !shown(
          HarnessActivityRow(style: .colorWhileActive, attention: .working, isArchived: true)))
      // An explicit choice ignores the session.
      #expect(try !shown(HarnessActivityRow(style: .monochrome, attention: .working)))
      #expect(try shown(HarnessActivityRow(style: .color)))
    }

    @Test(
      "A row's mark turns to color as its session starts and back as it stops",
      arguments: [false, true])
    func rowFollowsActivity(reduceMotion: Bool) throws {
      func row(_ attention: SessionAttentionState) -> some View {
        HarnessActivityRow(style: .colorWhileActive, attention: attention)
          .frame(width: 280, height: 32)
          .environment(\._accessibilityReduceMotion, reduceMotion)
      }
      let screen = OffscreenWindow(row(.idle), width: 280, height: 32)
      defer { screen.close() }
      #expect(!RenderSupport.shows(orange, in: try RenderSupport.capture(screen.host)))
      let showsOrange = { RenderSupport.shows(orange, in: try RenderSupport.capture(screen.host)) }
      screen.host.rootView = row(.working)
      #expect(try MainLoop.settle(until: { try showsOrange() }))
      screen.host.rootView = row(.idle)
      #expect(try MainLoop.settle(until: { try !showsOrange() }))
    }

    @Test("A new session's agent shows its mark in color unless the setting says otherwise")
    func newSessionAgent() throws {
      var configuration = ComposerSamples.codexConfiguration
      configuration.harness = "claude-native"
      func agent(_ style: HarnessIconStyle?) throws -> RenderSupport.Rendered {
        let store = try #require(UserDefaults(suiteName: "harness-icon-\(UUID())"))
        if let style { store.set(style.rawValue, forKey: InterfacePreferences.harnessIconKey) }
        return try RenderSupport.render(
          ConfigurationMenu(
            configuration: configuration, actions: ComposerActionLog().actions, showsAgent: true
          )
          .environment(\.composerLayoutStyle, .card)
          .defaultAppStorage(store),
          width: 600, height: 40, scheme: .dark, layout: .regular)
      }
      #expect(RenderSupport.shows(orange, in: try agent(nil)))
      #expect(RenderSupport.shows(orange, in: try agent(.colorWhileActive)))
      #expect(RenderSupport.shows(orange, in: try agent(.color)))
      let mono = try agent(.monochrome)
      #expect(!RenderSupport.shows(orange, in: mono))
      let hidden = try agent(.hidden)
      #expect(!RenderSupport.shows(orange, in: hidden))
      #expect(RenderSupport.inkedWidth(hidden) < RenderSupport.inkedWidth(mono))
    }
  }
#endif
