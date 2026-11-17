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
  final class CollectionSurroundings {
    var dock: CGFloat = 80
    var typeSize = DynamicTypeSize.large
    var layoutWidth = LayoutWidth.compact
    /// The launch's text rows unless a test hosts SwiftUI rows on purpose.
    var renderer = MessageTextRenderer.launchValue
    let focus = TranscriptFocus()
  }

  struct CollectionHost: View {
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
      .environment(\.layoutWidth, surroundings.layoutWidth)
      .environment(\.messageTextRenderer, surroundings.renderer)
    }
  }

  /// The transcript in a window, with its collection view and controller.
  struct CollectionScreen {
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

    /// Rests until idle measuring has nothing left within its reach: a loaded machine gives
    /// each of its passes less time.
    func restUntilMeasured() async {
      await rest()
      for _ in 0..<10 {
        let measured = controller.measurements
        await settle(.milliseconds(300))
        if controller.measurements == measured { return }
      }
    }

    /// Whether the same point of the same row is under the viewport's top.
    func isReading(
      _ anchor: TranscriptCollectionController.ReadingAnchor, within tolerance: CGFloat = 1
    ) -> Bool {
      guard let now = controller.readingAnchor() else { return false }
      return now.id == anchor.id && abs(now.offset - anchor.offset) < tolerance
    }
  }

  /// `turns` turns, then a short one that fits the window.
  @MainActor
  func collectionSession(turns: Int = 10, hasMore: Bool = false) -> LiveConversation {
    var rows = TranscriptFixture.turns(turns, startingAt: 10)
    rows += [
      TranscriptFixture.user("u-last", "Short?"),
      TranscriptFixture.answer("a-last", "Yes.", responseID: "r-last"),
    ]
    var state = ConversationViewState(header: TranscriptFixture.header, rows: rows)
    state.hasMoreHistory = hasMore
    return LiveConversation(state)
  }

  /// The transcript in a window of `size`, iPhone-sized by default.
  @MainActor
  func collectionScreen(
    _ conversation: LiveConversation, actions: ConversationActions = ConversationActions(),
    size: CGSize = CGSize(width: 393, height: 852), layoutWidth: LayoutWidth = .compact,
    renderer: MessageTextRenderer = .launchValue
  ) async throws -> CollectionScreen {
    let surroundings = CollectionSurroundings()
    surroundings.layoutWidth = layoutWidth
    surroundings.renderer = renderer
    let window = try InProcessWindow(
      CollectionHost(conversation: conversation, surroundings: surroundings, actions: actions),
      width: size.width, height: size.height,
      horizontalSizeClass: layoutWidth == .regular ? .regular : .compact)
    await window.settle(.milliseconds(300))
    let list = try #require(
      window.views(UICollectionView.self).first { $0.delegate is TranscriptCollectionController })
    let controller = try #require(list.delegate as? TranscriptCollectionController)
    return CollectionScreen(
      window: window, list: list, controller: controller, surroundings: surroundings)
  }

  /// The collection transcript on iPhone and iPad: what it measures, and where it keeps the
  /// reader as rows stream, arrive and page in above, and as a link sends them to a message.
  @Suite("Transcript collection scrolling", .serialized)
  @MainActor
  struct TranscriptCollectionScrollingTests {
    let log = HostLog()

    private var pagingActions: ConversationActions {
      var actions = ConversationActions()
      let log = self.log
      actions.loadOlder = { log.add("older") }
      return actions
    }

    @Test("Opening at a turn that fits follows the end, and a streamed reply keeps it in view")
    func followsStreaming() async throws {
      let conversation = collectionSession()
      let screen = try await collectionScreen(conversation)
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
      let conversation = collectionSession()
      let screen = try await collectionScreen(conversation)
      defer { screen.window.close() }
      await screen.drag(to: screen.offset - 600)
      #expect(!screen.controller.follow.follows)
      let anchor = try #require(screen.controller.readingAnchor())
      // Output below the reader leaves them on their row. (Rows above that idle measuring
      // reaches meanwhile move the offset with that row, so the offset itself may change.)
      conversation.stream("streamed", "A reply\n\nwith\n\nseveral\n\nparagraphs")
      await screen.window.settle(.milliseconds(20))
      #expect(
        screen.isReading(anchor),
        "\(String(describing: screen.controller.readingAnchor())) from \(anchor)")
      conversation.append(TranscriptFixture.user("u-next", "And then?"))
      await screen.settle()
      #expect(
        screen.isReading(anchor),
        "\(String(describing: screen.controller.readingAnchor())) from \(anchor)")
      #expect(screen.controller.follow.pill.isShown)
      screen.controller.jumpToLatest()
      // The jump is a short animated scroll; a loaded machine draws it slowly.
      for _ in 0..<20 where !screen.isAtEnd { await screen.settle(.milliseconds(100)) }
      #expect(screen.isAtEnd, "\(screen.offset) of \(screen.controller.maximumOffset)")
      #expect(screen.controller.follow.follows)
    }

    @Test("Jump to latest lands at the end when the bars below change during its scroll")
    func jumpLandsThroughInsets() async throws {
      let conversation = collectionSession()
      let screen = try await collectionScreen(conversation)
      defer { screen.window.close() }
      await screen.drag(to: screen.offset - 600)
      conversation.append(TranscriptFixture.user("u-next", "And then?"))
      // Idle measuring done, so nothing but the jump moves the list.
      await screen.restUntilMeasured()
      #expect(!screen.controller.follow.follows)
      screen.controller.jumpToLatest()
      #expect(screen.controller.isJumpingToEnd)
      // The composer shrinks, or a keyboard hides, before the scroll gets there.
      screen.surroundings.dock = 60
      await screen.settle(.milliseconds(100))
      #expect(screen.isAtEnd, "\(screen.offset) of \(screen.controller.maximumOffset)")
      #expect(screen.controller.follow.follows)
    }

    @Test("A jump whose scroll is cut short still lands at the end")
    func jumpLandsWhenCutShort() async throws {
      let conversation = collectionSession()
      let screen = try await collectionScreen(conversation)
      defer { screen.window.close() }
      await screen.drag(to: screen.offset - 600)
      await screen.restUntilMeasured()
      let start = screen.offset
      screen.controller.jumpToLatest()
      // Something stops the animated scroll where it started, without its end being reported.
      screen.list.setContentOffset(CGPoint(x: 0, y: start), animated: false)
      #expect(!screen.isAtEnd)
      let landing = Int(TranscriptCollectionController.jumpLanding * 1000)
      await screen.settle(.milliseconds(landing + 200))
      #expect(screen.isAtEnd, "\(screen.offset) of \(screen.controller.maximumOffset)")
    }

    @Test("Older rows landing above keep the reader on the row they were reading")
    func pagingKeepsPosition() async throws {
      let conversation = collectionSession(hasMore: true)
      let screen = try await collectionScreen(conversation, actions: pagingActions)
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
      let conversation = collectionSession(turns: 24)
      let screen = try await collectionScreen(conversation)
      defer { screen.window.close() }
      await screen.restUntilMeasured()
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
      let heights = controller.model.rows.map { controller.model.heights.measurement(of: $0.id) }
      for step in 1...6 { await screen.drag(to: end - CGFloat(step) * 150) }
      for step in 1...6 { await screen.drag(to: end - 900 + CGFloat(step) * 150) }
      // Rows measured before are not measured again; idle measuring between the moves may reach
      // rows that came within its reach.
      let again = controller.model.rows.indices.filter { index in
        guard let before = heights[index] else { return false }
        return controller.model.heights.measurement(of: controller.model.rows[index].id) != before
      }
      #expect(again.isEmpty, "measured again: \(again)")
      controller.jumpToLatest()
      await screen.settle(.milliseconds(600))
      let measured = controller.measurements
      conversation.stream("streamed", "One line")
      await screen.settle(.milliseconds(60))
      conversation.stream("streamed", "One line\n\nand another")
      await screen.settle(.milliseconds(60))
      // The streamed row each time, and the footer once its working line goes.
      #expect(controller.measurements - measured <= 4, "\(controller.measurements - measured)")
      #expect(screen.isAtEnd)
    }

    @Test("A message link scrolls its row into view, flashed, and stops following")
    func messageLink() async throws {
      let conversation = collectionSession(turns: 16)
      let screen = try await collectionScreen(conversation)
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
      let screen = try await collectionScreen(collectionSession(), renderer: .swiftUI)
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
