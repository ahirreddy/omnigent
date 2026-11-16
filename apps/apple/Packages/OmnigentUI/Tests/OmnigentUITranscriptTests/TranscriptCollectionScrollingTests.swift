#if os(iOS)
  import Observation
  import OmnigentViewTesting
  import SwiftUI
  import Testing
  import UIKit

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// What a test changes around the transcript: the composer and keyboard below it, and the
  /// text size.
  @MainActor
  @Observable
  private final class CollectionSurroundings {
    var dock: CGFloat = 80
    var typeSize = DynamicTypeSize.large
    let focus = TranscriptFocus()
  }

  private struct CollectionHost: View {
    let conversation: LiveConversation
    let surroundings: CollectionSurroundings
    let actions: ConversationActions

    var body: some View {
      TableTranscriptView(
        state: conversation.state, liveRows: nil, actions: actions,
        scrollToLatestRequest: conversation.scrollRequest
      )
      .safeAreaInset(edge: .bottom, spacing: 0) {
        Color.clear.frame(height: surroundings.dock)
      }
      .environment(\.dynamicTypeSize, surroundings.typeSize)
      .environment(\.transcriptFocus, surroundings.focus)
    }
  }

  /// The transcript in a window, with its collection view and controller.
  private struct CollectionScreen {
    let window: InProcessWindow
    let list: UICollectionView
    let controller: TranscriptCollectionController
    let surroundings: CollectionSurroundings

    var offset: CGFloat { list.contentOffset.y }

    var isAtEnd: Bool { abs(offset - controller.maximumOffset) < 1 }

    func settle(_ duration: Duration = .milliseconds(120)) async {
      await window.settle(duration)
    }

    /// Moves the content as a reader's drag does.
    func drag(to offset: CGFloat) async {
      controller.scrollViewWillBeginDragging(list)
      list.contentOffset.y = offset
      list.layoutIfNeeded()
      controller.scrollViewDidEndDragging(list, willDecelerate: false)
      await settle()
    }

    /// Lets idle measuring run: it starts once the reader has been still a while.
    func rest() async {
      await settle(.milliseconds(Int(TranscriptCollectionController.prefetchDelay * 1000) + 400))
    }

    /// Whether the same point of the same row is under the viewport's top.
    func isReading(
      _ anchor: TranscriptCollectionController.ReadingAnchor, within tolerance: CGFloat = 1
    ) -> Bool {
      guard let now = controller.readingAnchor() else { return false }
      return now.id == anchor.id && abs(now.offset - anchor.offset) < tolerance
    }
  }

  /// The collection transcript on iPhone and iPad: what it measures, and where it keeps the
  /// reader as rows stream, arrive and page in above, as the keyboard and composer cover the
  /// rows, as the window turns or resizes and as the text size changes.
  @Suite("Transcript collection scrolling", .serialized)
  @MainActor
  struct TranscriptCollectionScrollingTests {
    static let phone = CGSize(width: 393, height: 852)
    let log = HostLog()

    private var pagingActions: ConversationActions {
      var actions = ConversationActions()
      let log = self.log
      actions.loadOlder = { log.add("older") }
      return actions
    }

    /// `turns` turns, then a short one that fits the window.
    private func session(turns: Int = 10, hasMore: Bool = false) -> LiveConversation {
      var rows = TranscriptFixture.turns(turns, startingAt: 10)
      rows += [
        TranscriptFixture.user("u-last", "Short?"),
        TranscriptFixture.answer("a-last", "Yes.", responseID: "r-last"),
      ]
      var state = ConversationViewState(header: TranscriptFixture.header, rows: rows)
      state.hasMoreHistory = hasMore
      return LiveConversation(state)
    }

    private func screen(
      _ conversation: LiveConversation, actions: ConversationActions = ConversationActions(),
      size: CGSize = phone
    ) async throws -> CollectionScreen {
      let surroundings = CollectionSurroundings()
      let window = try InProcessWindow(
        CollectionHost(conversation: conversation, surroundings: surroundings, actions: actions),
        width: size.width, height: size.height)
      await window.settle(.milliseconds(300))
      let list = try #require(
        window.views(UICollectionView.self).first { $0.delegate is TranscriptCollectionController })
      let controller = try #require(list.delegate as? TranscriptCollectionController)
      return CollectionScreen(
        window: window, list: list, controller: controller, surroundings: surroundings)
    }

    @Test("Opening at a turn that fits follows the end, and a streamed reply keeps it in view")
    func followsStreaming() async throws {
      let conversation = session()
      let screen = try await screen(conversation)
      defer { screen.window.close() }
      #expect(screen.isAtEnd, "\(screen.offset) of \(screen.controller.maximumOffset)")
      #expect(screen.controller.follow.follows)
      var reply = "First"
      for step in 0..<6 {
        reply += "\n\nParagraph \(step) of a reply that keeps growing while it streams in."
        conversation.stream("streamed", reply)
        await screen.settle(.milliseconds(60))
        #expect(
          screen.isAtEnd, "step \(step): \(screen.offset) of \(screen.controller.maximumOffset)")
      }
      let row = try #require(screen.controller.model.index(of: "streamed"))
      #expect(!screen.controller.model.needsMeasure(at: row))
    }

    @Test("A reader who scrolled up stays put while output arrives; Jump to latest goes back")
    func readerStaysPut() async throws {
      let conversation = session()
      let screen = try await screen(conversation)
      defer { screen.window.close() }
      await screen.drag(to: screen.offset - 600)
      #expect(!screen.controller.follow.follows)
      let anchor = try #require(screen.controller.readingAnchor())
      let offset = screen.offset
      conversation.stream("streamed", "A reply\n\nwith\n\nseveral\n\nparagraphs")
      await screen.window.settle(.milliseconds(20))
      // Output below the reader moves nothing; rows above measured while they rest keep them on
      // their row.
      #expect(
        abs(screen.offset - offset) < 1,
        "\(screen.offset) from \(offset); \(screen.controller.remeasured)")
      conversation.append(TranscriptFixture.user("u-next", "And then?"))
      await screen.settle()
      #expect(
        screen.isReading(anchor),
        "\(String(describing: screen.controller.readingAnchor())) from \(anchor)")
      #expect(screen.controller.follow.pill.isShown)
      screen.controller.jumpToLatest()
      await screen.settle(.milliseconds(600))
      #expect(screen.isAtEnd)
      #expect(screen.controller.follow.follows)
    }

    @Test("Older rows landing above keep the reader on the row they were reading")
    func pagingKeepsPosition() async throws {
      let conversation = session(hasMore: true)
      let screen = try await screen(conversation, actions: pagingActions)
      defer { screen.window.close() }
      await screen.drag(to: 120)
      #expect(log.entries.contains("older"))
      let anchor = try #require(screen.controller.readingAnchor())
      conversation.state.isLoadingHistory = true
      await screen.settle()
      #expect(screen.isReading(anchor))
      conversation.state.rows.insert(contentsOf: TranscriptFixture.turns(4), at: 0)
      conversation.state.revision += 1
      conversation.state.isLoadingHistory = false
      conversation.state.historyReads += 1
      await screen.settle()
      #expect(screen.isReading(anchor))
      #expect(screen.offset > 400)
      // The new rows are measured while the reader rests, and the row read stays.
      await screen.rest()
      #expect(screen.isReading(anchor))
    }

    @Test("Rows are measured once: scrolling back over them and a streamed delta measure little")
    func measuresOnce() async throws {
      let conversation = session(turns: 24)
      let screen = try await screen(conversation)
      defer { screen.window.close() }
      await screen.rest()
      let controller = screen.controller
      let shown = screen.list.bounds
      let reach = shown.insetBy(
        dx: 0, dy: -shown.height * TranscriptCollectionController.prefetchReach)
      var unmeasuredBeyond = 0
      for index in controller.model.rows.indices {
        let rect = controller.frame(ofRow: index)
        if rect.minY >= reach.minY, rect.maxY <= reach.maxY {
          #expect(!controller.model.needsMeasure(at: index), "row \(index)")
        } else if rect.maxY < reach.minY, controller.model.needsMeasure(at: index) {
          unmeasuredBeyond += 1
        }
      }
      #expect(unmeasuredBeyond > 0)
      let end = screen.offset
      let measured = controller.measurements
      let heights = controller.model.rows.map { controller.model.heights.measurement(of: $0.id) }
      for step in 1...6 { await screen.drag(to: end - CGFloat(step) * 150) }
      for step in 1...6 { await screen.drag(to: end - 900 + CGFloat(step) * 150) }
      let changed = controller.model.rows.indices.filter {
        controller.model.heights.measurement(of: controller.model.rows[$0].id) != heights[$0]
      }.map {
        "\($0) \(String(describing: heights[$0])) -> \(String(describing: controller.model.heights.measurement(of: controller.model.rows[$0].id)))"
      }
      #expect(
        controller.measurements == measured,
        "\(controller.measurements - measured) more: \(changed)")
      controller.jumpToLatest()
      await screen.settle(.milliseconds(600))
      conversation.stream("streamed", "One line")
      await screen.settle(.milliseconds(60))
      conversation.stream("streamed", "One line\n\nand another")
      await screen.settle(.milliseconds(60))
      // The streamed row each time, and the footer once its working line goes.
      #expect(controller.measurements - measured <= 4, "\(controller.measurements - measured)")
      #expect(screen.isAtEnd)
    }

    @Test("The keyboard and a taller composer keep a follower at the end and a reader in place")
    func keyboardInsets() async throws {
      let conversation = session()
      let screen = try await screen(conversation)
      defer { screen.window.close() }
      #expect(screen.isAtEnd)
      let resting = screen.controller.insets.bottom
      screen.surroundings.dock = 420
      await screen.settle()
      #expect(screen.controller.insets.bottom - resting > 300)
      #expect(screen.isAtEnd, "\(screen.offset) of \(screen.controller.maximumOffset)")
      screen.surroundings.dock = 80
      await screen.settle()
      #expect(screen.isAtEnd)
      await screen.drag(to: screen.offset - 500)
      let anchor = try #require(screen.controller.readingAnchor())
      screen.surroundings.dock = 420
      await screen.settle()
      #expect(screen.isReading(anchor))
      #expect(!screen.controller.follow.follows)
    }

    @Test("Turning the window keeps the row read and measures the rows on screen at the width")
    func rotationKeepsPlace() async throws {
      let conversation = session(turns: 16)
      let screen = try await screen(conversation)
      defer { screen.window.close() }
      await screen.drag(to: screen.offset - 1400)
      let anchor = try #require(screen.controller.readingAnchor())
      let narrow = screen.controller.model.width
      let before =
        "\(screen.controller.insets) \(screen.controller.offsets.height(of: try #require(screen.controller.model.index(of: anchor.id))))"
      screen.window.window.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
      await screen.settle()
      let controller = screen.controller
      #expect(controller.model.width > narrow + 300)
      let now = try #require(controller.readingAnchor())
      #expect(now.id == anchor.id)
      let after =
        "\(controller.insets) \(controller.offsets.height(of: try #require(controller.model.index(of: anchor.id))))"
      #expect(
        abs(now.fraction - anchor.fraction) < 0.05,
        "\(now) vs \(anchor); before \(before), after \(after); \(controller.remeasured)")
      for index in controller.visibleRange {
        #expect(!controller.model.needsMeasure(at: index), "row \(index)")
      }
      screen.window.window.frame = CGRect(origin: .zero, size: Self.phone)
      await screen.settle()
      #expect(controller.readingAnchor()?.id == anchor.id)
    }

    @Test("A larger text size measures the rows again, and the reader keeps their row")
    func dynamicType() async throws {
      let conversation = session(turns: 16)
      let screen = try await screen(conversation)
      defer { screen.window.close() }
      await screen.drag(to: screen.offset - 1400)
      let anchor = try #require(screen.controller.readingAnchor())
      let controller = screen.controller
      let row = try #require(controller.model.index(of: anchor.id))
      let before = controller.model.height(at: row)
      screen.surroundings.typeSize = .accessibility2
      await screen.settle(.milliseconds(300))
      #expect(controller.model.height(at: row) > before * 1.2)
      #expect(controller.readingAnchor()?.id == anchor.id)
      for index in controller.visibleRange {
        #expect(!controller.model.needsMeasure(at: index), "row \(index)")
      }
    }

    @Test("A message link scrolls its row into view, flashed, and stops following")
    func messageLink() async throws {
      let conversation = session(turns: 16)
      let screen = try await screen(conversation)
      defer { screen.window.close() }
      let focus = screen.surroundings.focus
      focus.focus("u12", in: TranscriptFixture.header.id)
      await screen.settle(.milliseconds(500))
      let controller = screen.controller
      #expect(controller.visibleRowIDs.contains("u12"), "\(controller.visibleRowIDs)")
      #expect(focus.messageID(in: TranscriptFixture.header.id) == nil)
      #expect(focus.flashedRowID == "u12")
      #expect(!controller.follow.follows)
    }

    @Test("A host's measured height is the height SwiftUI lays the row out at in its cell")
    func measuredMatchesShown() async throws {
      let screen = try await screen(session())
      defer { screen.window.close() }
      let controller = screen.controller
      var checked = 0
      for case let cell as TranscriptCollectionCell in screen.list.visibleCells {
        guard let host = cell.host, let id = host.shownID,
          let index = controller.model.index(of: id)
        else { continue }
        let measured = try #require(controller.model.heights.measurement(of: id))
        #expect(abs(cell.bounds.height - measured.height) < 1, "\(id)")
        #expect(abs(controller.offsets.height(of: index) - measured.height) < 1, "\(id)")
        checked += 1
      }
      #expect(checked >= 2)
    }
  }
#endif
