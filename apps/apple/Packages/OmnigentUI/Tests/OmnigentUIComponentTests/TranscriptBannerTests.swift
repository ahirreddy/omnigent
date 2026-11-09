#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Transcript banners and empty states", .serialized)
  @MainActor
  struct TranscriptBannerTests {
    private typealias Fixture = TranscriptFixture

    @Test("The failure banner offers Resume only when the session can resume")
    func failureBanner() throws {
      let log = HostLog()
      let screen = transcriptScreen(
        FailureBanner(message: "It broke", resume: { log.add("resume") }))
      defer { screen.close() }
      #expect(try screen.shows("The last turn failed"))
      #expect(try screen.shows("It broke"))
      #expect(try screen.shows("Resume session"))
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(log.entries == ["resume"])

      let stuck = transcriptScreen(FailureBanner(message: "It broke", resume: nil))
      defer { stuck.close() }
      #expect(try !stuck.shows("Resume session"))
    }

    @Test("The error banner's Dismiss and Retry each do their own thing")
    func errorBannerActions() throws {
      let log = HostLog()
      let screen = transcriptScreen(
        ErrorBanner(
          message: "No connection", dismiss: { log.add("dismiss") }, retry: { log.add("retry") }))
      defer { screen.close() }
      #expect(try screen.shows("No connection"))
      let count = screen.controlFrames.count
      try screen.clickControl(at: count - 2)
      try screen.clickControl(at: count - 1)
      #expect(log.entries == ["dismiss", "retry"])
    }

    @Test("An error banner with no actions has only its overflow menu")
    func errorBannerAlone() throws {
      let screen = transcriptScreen(ErrorBanner(message: "No connection", title: "Offline"))
      defer { screen.close() }
      #expect(try screen.shows("Offline"))
      #expect(try !screen.shows("Retry"))
      #expect(screen.controlFrames.count == 1)
      let menu = try screen.openMenu(center(of: screen.controlFrames[0]))
      #expect(menu.items.map(\.title) == ["Copy Error"])
      SystemSideEffects.reset()
      try screen.choose("Copy Error", in: menu)
      #expect(copiedText() == "No connection")
    }

    @Test("A notice's overflow copy isn't called an error, and it has none without text to copy")
    func noticeMenu() throws {
      let screen = transcriptScreen(
        StatusBanner(
          kind: .notice, title: "Moved", detail: "Elsewhere", copyText: "Elsewhere", identifier: "n"
        ))
      defer { screen.close() }
      let menu = try screen.openMenu(center(of: screen.controlFrames[0]))
      #expect(menu.items.map(\.title) == ["Copy"])

      let bare = transcriptScreen(
        StatusBanner(kind: .uncertain, title: nil, detail: "Unclear", identifier: "u"))
      defer { bare.close() }
      #expect(try bare.shows("Unclear"))
      #expect(bare.controlFrames.isEmpty)
    }

    @Test("Each banner kind has its own glyph")
    func bannerKinds() {
      let kinds: [StatusBannerKind] = [.failure, .uncertain, .notice]
      #expect(Set(kinds.map(\.systemImage)).count == 3)
    }

    @Test("A superseded session opens its successor, or just says so without a host")
    func superseded() throws {
      let log = HostLog()
      let section = EventSection(
        id: "superseded", title: "Moved on", summary: "Continued elsewhere", sessionId: "next")
      let screen = transcriptScreen(
        SupersededBanner(section: section, target: "next"),
        actions: ConversationActions(openSession: { log.add($0) }))
      defer { screen.close() }
      #expect(try screen.shows("Moved on"))
      try screen.clickControl(at: 0)
      #expect(log.entries == ["next"])

      let readOnly = transcriptScreen(SupersededBanner(section: section, target: "next"))
      defer { readOnly.close() }
      #expect(try readOnly.shows("Continued elsewhere"))
      #expect(readOnly.controlFrames.isEmpty)
    }

    @Test("Startup is a spinner line until the launch fails, then a banner with the reason")
    func startup() throws {
      let starting = transcriptScreen(
        StartupLine(section: EventSection(id: "startup", title: "", summary: "Provisioning")))
      defer { starting.close() }
      #expect(try starting.shows("Provisioning"))

      let failed = transcriptScreen(
        StartupLine(
          section: EventSection(
            id: "startup", title: "", summary: "Sandbox failed",
            details: [
              DetailSection(id: "stage", title: "Stage", text: "failed"),
              DetailSection(id: "error", title: "Error", text: "Out of disk"),
            ])))
      defer { failed.close() }
      #expect(try failed.shows("Sandbox failed"))
      #expect(try failed.shows("Out of disk"))
    }

    @Test("An empty conversation says what to do next, for each kind of empty")
    func emptyText() {
      var state = ConversationViewState(header: Fixture.header)
      #expect(EmptyTranscriptView.title(state) == EmptyTranscriptView.heading)
      #expect(EmptyTranscriptView.detail(state) == "Send a message to get started.")
      state.header.readOnly = true
      #expect(EmptyTranscriptView.detail(state) == "This session has no messages yet.")
      state.hasMoreHistory = true
      #expect(EmptyTranscriptView.title(state) == "No messages on this page")
      #expect(EmptyTranscriptView.detail(state) == "Load earlier messages to continue.")
    }

    @Test("An empty conversation draws loading first, never the empty heading")
    func emptyStates() throws {
      var state = ConversationViewState(header: Fixture.header)
      state.isHydrating = true
      let loading = transcriptScreen(EmptyTranscriptView(state: state))
      defer { loading.close() }
      #expect(try loading.shows("Loading conversation\u{2026}"))
      #expect(try !loading.shows(EmptyTranscriptView.heading))

      state.isHydrating = false
      let empty = transcriptScreen(EmptyTranscriptView(state: state))
      defer { empty.close() }
      #expect(try empty.shows(EmptyTranscriptView.heading))

      state.turnStartedAt = Date(timeIntervalSince1970: 0)
      let running = transcriptScreen(EmptyTranscriptView(state: state))
      defer { running.close() }
      #expect(try !running.shows(EmptyTranscriptView.heading))
    }

    @Test("The terminal pane shows the surface, its stage, or the way back")
    func terminalStates() throws {
      let log = HostLog()
      func pane(_ status: TerminalStatus, resumes: Bool = true) -> OffscreenWindow<AnyView> {
        transcriptScreen(
          TerminalPane(status: status, resume: resumes ? { log.add("resume") } : nil) {
            Text("The surface")
          })
      }
      let ready = pane(.ready)
      defer { ready.close() }
      #expect(try ready.shows("The surface"))

      let staged = pane(.startingUp(stage: "Provisioning"))
      defer { staged.close() }
      #expect(try staged.shows("Provisioning\u{2026}"))
      let starting = pane(.startingUp(stage: nil))
      defer { starting.close() }
      #expect(try starting.shows("Starting up\u{2026}"))

      let offline = pane(.sandboxOffline)
      defer { offline.close() }
      #expect(try offline.shows("The sandbox is offline."))
      #expect(try offline.shows("Resume sandbox"))
      try offline.clickControl(at: 0)
      #expect(log.entries == ["resume"])

      let harness = pane(.harnessNotRunning)
      defer { harness.close() }
      #expect(try harness.shows("The harness is not running."))
      #expect(try harness.shows("Resume session"))

      let resuming = pane(.resuming)
      defer { resuming.close() }
      #expect(try resuming.shows("Resuming\u{2026}"))
      // While it resumes, the button can't take a second click.
      #expect(resuming.controlFrames.isEmpty)

      let noHost = pane(.sandboxOffline, resumes: false)
      defer { noHost.close() }
      #expect(noHost.controlFrames.isEmpty)
    }

    @Test("The agent info popover lists only what the agent has")
    func agentInfo() throws {
      let full = transcriptScreen(
        AgentInfoPopover(info: AgentInfo(name: "Otto", tools: ["Bash"], policies: ["No main"])))
      defer { full.close() }
      for text in ["Otto", "Tools", "Bash", "Policies", "No main"] {
        #expect(try full.shows(text), "\(text)")
      }
      let bare = transcriptScreen(AgentInfoPopover(info: AgentInfo(name: "Otto")))
      defer { bare.close() }
      #expect(try !bare.shows("Tools"))
      #expect(try !bare.shows("Policies"))
    }

    @Test("The terminal placeholder names its harness")
    func placeholder() throws {
      let screen = transcriptScreen(TerminalPlaceholderView(harness: nil))
      defer { screen.close() }
      #expect(try screen.shows("Terminal surface placeholder."))
    }

    private func center(of frame: CGRect) -> CGPoint {
      CGPoint(x: frame.midX, y: frame.midY)
    }
  }
#endif
