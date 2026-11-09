#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI

  @testable import OmnigentUIComponents

  /// Hosts a piece of the transcript off screen, with animations off so a click's result is there
  /// when the click returns.
  @MainActor
  func transcriptScreen(
    _ view: some View, actions: ConversationActions = ConversationActions(), width: CGFloat = 700,
    height: CGFloat = 500, layout: LayoutWidth = .regular
  ) -> OffscreenWindow<AnyView> {
    OffscreenWindow(
      AnyView(
        view
          .environment(\.conversationActions, actions)
          .environment(\.layoutWidth, layout)
          .environment(\.flattensGlass, true)
          .transaction { transaction in
            transaction.disablesAnimations = true
            transaction.animation = nil
          }
          .frame(width: width, height: height, alignment: .topLeading)),
      width: width, height: height)
  }

  /// Lets what a click or a view's `task` started finish: a run loop spun inside the test's job
  /// would hold those tasks back on the main queue, so this suspends instead.
  @MainActor
  func letTasksRun(_ screen: OffscreenWindow<AnyView>, milliseconds: Int = 60) async throws {
    try await Task.sleep(for: .milliseconds(milliseconds))
    screen.settle(0.02)
  }

  /// Whether `condition` comes true within ten seconds, for what takes however long the machine
  /// and the suites running beside this one let it.
  @MainActor
  func waitUntil(
    _ screen: OffscreenWindow<AnyView>, _ condition: @MainActor () throws -> Bool
  ) async throws -> Bool {
    for _ in 0..<100 {
      if try condition() { return true }
      try await letTasksRun(screen, milliseconds: 100)
    }
    return false
  }

  /// The selection popup reads the selection when its event monitor sees an event, which only
  /// `NSApp.sendEvent` delivers; a key up reaches nothing else here.
  @MainActor
  func announceSelection(_ screen: OffscreenWindow<AnyView>) async throws {
    let event = NSEvent.keyEvent(
      with: .keyUp, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: screen.window.windowNumber,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0)
    guard let event else { throw OffscreenWindowError.notFound("key up event") }
    NSApp.sendEvent(event)
    try await letTasksRun(screen)
  }

  /// Where named pieces of a view landed, from the top left of the screen.
  @MainActor
  final class FrameLog {
    fileprivate(set) var frames: [String: CGRect] = [:]
  }

  extension View {
    /// Records this view's frame under `name`, in window coordinates.
    func recordingFrame(_ name: String, in log: FrameLog) -> some View {
      onGeometryChange(for: CGRect.self) { proxy in
        proxy.frame(in: .global)
      } action: { frame in
        log.frames[name] = frame
      }
    }
  }

  extension OffscreenWindow {
    /// The first context menu found on a grid of points: a menu only answers over drawn content.
    func firstContextMenu(step: CGFloat = 12) throws -> NSMenu? {
      for row in stride(from: step / 2, to: host.bounds.height, by: step) {
        for column in stride(from: step / 2, to: host.bounds.width, by: step) {
          if let menu = try contextMenu(at: CGPoint(x: column, y: row)) { return menu }
        }
      }
      return nil
    }
  }

  /// What the test's private pasteboard holds.
  @MainActor
  func copiedText() -> String? {
    SystemSideEffects.pasteboard.string(forType: .string)
  }

  /// A menu's item titles, without the empty one a button-style menu starts with.
  @MainActor
  func titles(of menu: NSMenu) -> [String] {
    menu.items.map(\.title).filter { !$0.isEmpty }
  }

  /// What the views under test asked the host to do, in order.
  @MainActor
  final class HostLog {
    private(set) var entries: [String] = []

    func add(_ entry: String) {
      entries.append(entry)
    }

    func clear() {
      entries.removeAll()
    }
  }

  /// Rows of each kind, with only what a test cares about spelled out.
  nonisolated enum TranscriptFixture {
    static let header = SessionHeader(id: "session-1", title: "A session")

    static func activityRow(
      _ kind: ActivityKind, id: String = "row", title: String = "Title", summary: String = "",
      status: String? = nil, details: [DetailSection] = [], isFailure: Bool = false,
      recovery: FailureRecovery? = nil, isStreaming: Bool = false,
      attachments: [Attachment] = []
    ) -> Row {
      Row(
        id: id, role: .tool, isStreaming: isStreaming,
        activity: Activity(
          kind: kind, title: title, summary: summary, status: status, details: details,
          isFailure: isFailure, recovery: recovery),
        attachments: attachments)
    }

    static func toolCall(
      _ id: String, title: String = "Bash", summary: String = "ls -la",
      status: String? = "completed",
      details: [DetailSection] = [], isFailure: Bool = false, attachments: [Attachment] = []
    ) -> Row {
      Row(
        id: id, role: .tool,
        activity: Activity(
          kind: .toolCall, title: title, summary: summary, status: status, details: details,
          isFailure: isFailure),
        attachments: attachments, callId: id, responseId: "resp-1")
    }

    static func toolResult(
      _ id: String, callID: String, output: String = "total 0", isFailure: Bool = false
    ) -> Row {
      Row(
        id: id, role: .tool,
        activity: Activity(
          kind: .toolResult, title: "Result", status: isFailure ? "failed" : "completed",
          details: [DetailSection(id: "output", title: "Output", text: output, isCode: true)],
          isFailure: isFailure),
        callId: callID, responseId: "resp-1")
    }

    static func user(_ id: String, _ text: String = "A question") -> Row {
      Row(id: id, role: .user, text: text)
    }

    static func answer(_ id: String, _ text: String = "An answer", responseID: String = "resp-1")
      -> Row
    {
      Row(id: id, role: .assistant, text: text, responseId: responseID)
    }
  }
#endif
