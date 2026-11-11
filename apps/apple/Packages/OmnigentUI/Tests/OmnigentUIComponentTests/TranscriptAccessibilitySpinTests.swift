#if os(macOS) && DEBUG
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// A transcript in a window an assistive client has read, its reader above the end while
  /// output streams below. The hang this looks for never ends: the main thread stays inside one
  /// layout, so the scenario runs in a process of its own, which a watchdog thread ends.
  @Suite("Transcript read by an assistive client", .serialized)
  @MainActor
  struct TranscriptAccessibilitySpinTests {
    private static let turns = 12
    private static let lastTurnAnswers = 3
    private static let height: CGFloat = 480
    private static let dock: CGFloat = 148
    /// How far above the end the reader is, in turn and moving away from it: whether the layout
    /// ends depends on where the last rows fall against the edge the stack places to.
    private static let readerDistances: [CGFloat] = [140, 380]
    /// How far each scroll moves the reader, and the chunks streamed at each distance.
    private static let step: CGFloat = 80
    private static let streamedChunks = 8
    /// How long the main thread may stay away from its run loop.
    private static let stallLimit: TimeInterval = 5

    private enum Failure: Int32 {
      case stalled = 71
      case noAssistiveClient = 72
      case readerFollows = 73
      case readerMoved = 74
    }

    @Test("Output streaming below a reader above the end leaves the main thread free")
    func outputBelowAReader() async {
      await #expect(processExitsWith: .success) {
        try await TranscriptAccessibilitySpinTests.streamBelowAReader()
      }
    }

    @Test("An assistive client reads the rows far above the window too")
    func rowsFarFromTheWindowAreRead() async throws {
      let window = try await Self.open(Self.session(), probe: AssistiveClientProbe())
      defer { window.close() }

      try window.withAccessibilityTree {
        var read: [String] = []
        for _ in 0..<2 {
          read = Self.readAccessibility(under: window.window)
          window.settle(0.3)
        }
        #expect(read.contains { $0.contains("And the last step?") })
        // A question far above is also in the rail; its answer's text is only in its row.
        #expect(read.contains("first point about step 2"))
        #expect(AssistiveClientNotice.isWritten)
      }
    }

    private static func answer(_ turn: Int) -> String {
      "## Step \(turn)\n\nThe change touches `Sources/App/File\(turn).swift` and its tests. "
        + "It keeps the **old** behaviour for existing callers and adds a new path.\n\n"
        + "- first point about step \(turn)\n- second point, a little longer than the first\n"
        + "- third point\n\n```swift\nlet value\(turn) = compute(\(turn))\n```\n\n"
        + "Then a closing paragraph that wraps over a couple of lines at the column's width so "
        + "the row has a realistic height when it is laid out in the transcript."
    }

    /// Tall answers, then a last turn too long for the window that ends in a short row: the
    /// opening leaves the reader above the end, and the last rows are far shorter than the
    /// height a lazy stack estimates for rows it has not placed.
    private static func session() -> LiveConversation {
      var rows = (1...turns).flatMap { turn -> [Row] in
        [
          TranscriptFixture.user("u\(turn)", "Look at step \(turn) please"),
          TranscriptFixture.answer("a\(turn)", answer(turn), responseID: "r\(turn)"),
        ]
      }
      rows.append(TranscriptFixture.user("u-last", "And the last step?"))
      for part in 1...lastTurnAnswers {
        rows.append(
          TranscriptFixture.answer(
            "a-last\(part)", answer(turns + part), responseID: "r-last\(part)"))
      }
      rows.append(TranscriptFixture.answer("done", "Done.", responseID: "r-done"))
      return LiveConversation(ConversationViewState(header: TranscriptFixture.header, rows: rows))
    }

    /// The answer being streamed, `chunks` chunks in.
    private static func streamed(_ chunks: Int) -> Row {
      Row(
        id: "live", role: .assistant,
        text: "Working on it" + String(repeating: " and more", count: chunks), isStreaming: true,
        responseId: "r-live")
    }

    private nonisolated static func end(_ failure: Failure, _ reason: String) -> Never {
      FileHandle.standardError.write(Data("\(reason)\n".utf8))
      _exit(failure.rawValue)
    }

    private static func streamBelowAReader() async throws {
      let watch = MainThreadWatch(threshold: stallLimit) { line in
        guard line.hasPrefix("STALL main thread busy") else { return }
        end(.stalled, line)
      }
      watch.start()
      defer { watch.stop() }

      let assistiveClient = AssistiveClientProbe()
      let conversation = session()
      let window = try await open(conversation, probe: assistiveClient)
      defer { window.close() }

      try window.withAccessibilityTree {
        for _ in 0..<2 {
          readAccessibility(under: window.window)
          window.settle(0.3)
        }
        guard assistiveClient.isOn else {
          end(.noAssistiveClient, "reading the window did not switch accessibility on")
        }

        let driver = TranscriptScrollDriver(screen: window)
        var chunks = 0
        for distance in readerDistances {
          for _ in 0..<3 {
            let place = driver.maximumOffset - distance
            let direction: CGFloat = place < driver.offset ? -1 : 1
            for offset in stride(from: driver.offset, to: place, by: direction * step) {
              driver.move(to: offset)
            }
            driver.move(to: place)
          }
          guard try isAway(window) else {
            end(.readerFollows, "\(distance) above the end, the reader still follows the output")
          }

          for _ in 0..<streamedChunks {
            if conversation.state.rows.last?.id == "live" { conversation.state.rows.removeLast() }
            conversation.state.rows.append(streamed(chunks))
            conversation.state.revision += 1
            chunks += 1
            window.settle(0.05)
          }
          guard try isAway(window) else {
            end(.readerMoved, "\(distance) above the end, the output took the reader to the end")
          }
        }
      }
    }

    /// The transcript in a window, opened at its end, with `probe` told who reads it.
    private static func open(
      _ conversation: LiveConversation, probe: AssistiveClientProbe
    ) async throws -> OffscreenWindow<AnyView> {
      let window = transcriptScreen(
        DockedTranscriptHost(
          conversation: conversation, pane: TranscriptPane(width: 900, dock: dock)
        )
        .background { AssistiveClientReader(probe: probe) },
        width: 1200, height: height)
      window.settle(0.5)
      try await letTasksRun(window, milliseconds: 600)
      return window
    }

    /// Whether the reader is away from the end: the pill offers the way back, and reads
    /// "New output" once output has arrived below them.
    private static func isAway(_ window: OffscreenWindow<AnyView>) throws -> Bool {
      try window.shows("Jump to latest") || window.shows("New output")
    }

    /// Reads every accessibility element under `root`, as an assistive client walking a window,
    /// and returns the text the elements gave.
    @discardableResult
    private static func readAccessibility(under root: NSObject) -> [String] {
      var read: [String] = []
      var pending: [Any] = [root]
      while let next = pending.popLast() {
        guard let element = next as? NSObject else { continue }
        for name in [
          "accessibilityRole", "accessibilityLabel", "accessibilityValue",
          "accessibilityIdentifier",
        ]
        where element.responds(to: NSSelectorFromString(name)) {
          if let text = element.value(forKey: name) as? String { read.append(text) }
        }
        if element.responds(to: NSSelectorFromString("accessibilityChildren")) {
          pending.append(contentsOf: element.value(forKey: "accessibilityChildren") as? [Any] ?? [])
        }
      }
      return read
    }
  }

  /// Whether the window's views are being read by an assistive client.
  @MainActor
  private final class AssistiveClientProbe {
    var isOn = false
  }

  private struct AssistiveClientReader: View {
    let probe: AssistiveClientProbe
    @Environment(\.accessibilityEnabled) private var isOn

    var body: some View {
      Color.clear.onChange(of: isOn, initial: true) { _, isOn in probe.isOn = isOn }
    }
  }
#endif
