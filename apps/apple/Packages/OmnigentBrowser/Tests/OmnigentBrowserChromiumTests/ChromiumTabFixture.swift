#if os(macOS)
  import AppKit
  import Darwin
  import Foundation
  import OWLProtocol
  import OmnigentBrowser
  import OmnigentViewTesting
  import Testing

  @testable import OmnigentBrowserChromium
  @testable import OmnigentWebLayer

  /// A tab of an engine whose session looks ready but has no host. What the tab would send
  /// is recorded, and host messages are delivered by hand.
  @MainActor
  final class ChromiumTabFixture {
    struct Sent {
      let kind: OWLMessageKind
      let target: UInt64
      let fields: WireDecoder
    }

    let session: Session
    let engine: ChromiumBrowserEngine
    let tab: ChromiumBrowserTab
    let recorder = RecordingTabDelegate()
    let root: URL
    var sent: [Sent] = []

    var webView: WebView { tab.webView }

    func agentInput() throws -> ChromiumAgentInput {
      try #require(tab.agentInput as? ChromiumAgentInput)
    }

    init(withDelegate: Bool = true) throws {
      SystemSideEffects.install()
      root = FileManager.default.temporaryDirectory
        .appending(path: "owl-chromium-tests-\(UUID().uuidString)")
      session = Session(
        configuration: SessionConfiguration(
          hostAppURL: root.appending(path: "absent.app"), rootCacheURL: root))
      engine = ChromiumBrowserEngine.attach(to: session)
      session.hostMinor = UInt64(OWL_PROTOCOL_MINOR)
      session.state = .ready(
        HostInfo(
          pid: 1, cefVersion: "cef-test", chromiumVersion: "test", protocolVersion: "1.3",
          renderMode: .ioSurface, spawnDuration: .zero, helloDuration: .zero, readyDuration: .zero,
          hostInitMilliseconds: 0))
      let profile = BrowserProfile(identifier: "tests", persistence: .ephemeral)
      let made = try engine.makeTab(profile: profile, initialURL: nil)
      tab = try #require(made as? ChromiumBrowserTab)
      tab.webView.status = .live
      if withDelegate { tab.delegate = recorder }
      session.outgoingTap = { [weak self] kind, target, fields in
        self?.sent.append(Sent(kind: kind, target: target, fields: fields))
      }
    }

    deinit {
      try? FileManager.default.removeItem(at: root)
    }

    /// Delivers a host message to the tab's view.
    func receive(_ kind: OWLMessageKind, target: UInt64? = nil, _ fields: WireEncoder) throws {
      session.handle(
        IncomingMessage(
          kindValue: kind.rawValue, request: 0, target: target ?? webView.id,
          protocolMajor: UInt16(OWL_PROTOCOL_MAJOR), fields: try WireDecoder(fields.bytes),
          port: nil))
    }

    func last(_ kind: OWLMessageKind) -> WireDecoder? {
      sent.last { $0.kind == kind }?.fields
    }

    /// Gives the session a channel with a peer, so requests wait for a reply; no host runs.
    func connect() throws {
      session.outgoingTap = nil
      let channel = try HostChannel.listen(
        serviceName: "ai.omnigent.owl.test.\(getpid()).\(UUID().uuidString.prefix(8))")
      var name = mach_port_t(MACH_PORT_NULL)
      #expect(mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &name) == KERN_SUCCESS)
      #expect(
        mach_port_insert_right(
          mach_task_self_, name, name, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
          == KERN_SUCCESS)
      try channel.adoptPeer(MachSendRight(name: name))
      session.channel = channel
    }

    /// Answers the oldest request the session is waiting on.
    func answer(_ fields: WireEncoder) async throws {
      #expect(await eventually { !self.session.replies.isEmpty })
      let id = try #require(session.replies.keys.min())
      session.handle(
        IncomingMessage(
          kindValue: .max, request: id, target: 0, protocolMajor: 1,
          fields: try WireDecoder(fields.bytes), port: nil))
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
      for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
      }
      return condition()
    }
  }

  /// Records what a tab tells its owner.
  @MainActor
  final class RecordingTabDelegate: BrowserTabDelegate {
    var requested: [BrowserPrompt] = []
    var cancelled: [BrowserPrompt] = []
    var popups: [BrowserPopup] = []
    var blocked: [BrowserBlockedPopup] = []
    var downloads: [BrowserDownload] = []

    func tab(_ tab: any BrowserTab, didRequest prompt: BrowserPrompt) { requested.append(prompt) }
    func tab(_ tab: any BrowserTab, didCancel prompt: BrowserPrompt) { cancelled.append(prompt) }
    func tab(_ tab: any BrowserTab, didOpen popup: BrowserPopup) { popups.append(popup) }
    func tab(_ tab: any BrowserTab, didBlock popup: BrowserBlockedPopup) { blocked.append(popup) }
    func tab(_ tab: any BrowserTab, didStart download: BrowserDownload) {
      downloads.append(download)
    }
  }

  /// A policy that refuses everything.
  nonisolated struct DenyEverything: BrowserURLPolicy {
    var rules: BrowserURLRules { BrowserURLRules() }
    func evaluate(_ url: URL) -> BrowserURLDecision { .deny("refused in a test") }
  }
#endif
