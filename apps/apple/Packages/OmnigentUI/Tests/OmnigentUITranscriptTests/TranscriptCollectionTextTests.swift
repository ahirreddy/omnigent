#if os(iOS)
  import OmnigentViewTesting
  import SwiftUI
  import Testing
  import UIKit

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The iPhone and iPad collection transcript's text rows: settled messages drawn from the
  /// shared document builder and raster, how they size, which rows they take, the prewarm that
  /// draws them ahead, and their place in the list.
  @Suite("Transcript collection text rows", .serialized)
  @MainActor
  struct TranscriptCollectionTextTests {
    @Test("An answer draws as one run down the column, as tall as its drawing and the row's gap")
    func answerSizing() throws {
      let style = textRowStyle()
      #expect(style.isEnabled)
      let answer = TranscriptFixture.answer("a1", "## Step\n\nA paragraph with `code`.\n\n- one")
      let (view, window) = try shownTextRow(answer, style: style)
      defer { window.close() }
      let run = try #require(view.runView)
      let metrics = style.metrics(width: textRowWidth)
      #expect(run.frame.minX == metrics.columnX)
      #expect(run.raster.width == metrics.columnWidth)
      #expect(run.image.showsDrawing)
      #expect(
        view.idealHeight(at: textRowWidth)
          == (run.raster.size.height + Theme.Spacing.row).rounded(.up))
      // Far from view, the same height from the run's size, with no view.
      let message = try #require(style.message(for: textRow(answer), version: 0))
      #expect(
        style.measuredHeight(of: message, width: textRowWidth) == view.idealHeight(at: textRowWidth)
      )
    }

    @Test("A prompt hugs its text in a bubble at the column's trailing edge")
    func promptSizing() throws {
      let style = textRowStyle()
      let (view, window) = try shownTextRow(TranscriptFixture.user("u1", "Short?"), style: style)
      defer { window.close() }
      let metrics = style.metrics(width: textRowWidth)
      let frames = try #require(view.frames)
      let bubble = try #require(frames.bubble)
      #expect(!view.bubbleView.isHidden)
      #expect(abs(bubble.maxX - (metrics.columnX + metrics.columnWidth)) < 0.5)
      #expect(frames.run.width < 100)
      #expect(abs(frames.run.minX - (bubble.minX + Theme.Spacing.large)) < 0.5)
      #expect(
        view.idealHeight(at: textRowWidth) == (bubble.height + Theme.Spacing.row).rounded(.up))
      #expect(view.accessibilityLabel == "You said")
    }

    @Test("An answer's \"Worked for\" line sits under its text, in the row's height")
    func workedLine() throws {
      let style = textRowStyle()
      let (view, window) = try shownTextRow(
        TranscriptFixture.answer("a-worked", "Done."),
        decoration: MessageDecoration(workedFor: 12), style: style)
      defer { window.close() }
      let label = try #require(view.workedLabel)
      let run = try #require(view.runView)
      #expect(!label.isHidden)
      #expect(label.text == TurnElapsed.worked(12))
      #expect(abs(label.frame.minY - (run.raster.size.height + Theme.Spacing.small)) < 0.5)
      #expect(view.idealHeight(at: textRowWidth) >= label.frame.maxY + Theme.Spacing.row)
    }

    @Test("Text rows draw settled answers and prompts; other messages stay SwiftUI's")
    func whichRowsDraw() throws {
      let style = textRowStyle()
      func draws(_ message: Row, _ decoration: MessageDecoration = MessageDecoration()) -> Bool {
        style.message(for: textRow(message, decoration: decoration), version: 0) != nil
      }
      #expect(draws(TranscriptFixture.answer("a", "Settled **text**")))
      #expect(draws(TranscriptFixture.user("u", "A prompt")))
      #expect(draws(TranscriptFixture.answer("code", "Run:\n\n```swift\nlet x = 1\n```")))
      var streaming = TranscriptFixture.answer("s", "Still going")
      streaming.isStreaming = true
      #expect(!draws(streaming))
      // The latest answer's action row is SwiftUI's.
      #expect(
        !draws(TranscriptFixture.answer("last", "Done"), MessageDecoration(showsActions: true)))
      // Display math and a diagram are blocks only SwiftUI draws.
      #expect(!draws(TranscriptFixture.answer("math", "Cost:\n\n$$\nT(n) = n\n$$")))
      #expect(!draws(TranscriptFixture.answer("graph", "```mermaid\ngraph TD\n  A --> B\n```")))
      var interrupted = TranscriptFixture.answer("i", "Partial")
      interrupted.interrupted = true
      #expect(!draws(interrupted))
      #expect(!draws(TranscriptFixture.user("long", String(repeating: "word ", count: 3_000))))
      // Off, or in CLI style, every row is SwiftUI's.
      let off = textRowStyle { $0.messageTextRenderer = .swiftUI }
      #expect(off.message(for: textRow(TranscriptFixture.answer("a", "Text")), version: 0) == nil)
    }

    @Test("A larger text size draws the text larger, and the row taller")
    func dynamicType() throws {
      let answer = TranscriptFixture.answer("a-type", "A paragraph that wraps onto more lines.")
      let regular = textRowStyle()
      let large = textRowStyle { $0.dynamicTypeSize = .accessibility2 }
      #expect(large.ramp.body > regular.ramp.body + 6)
      let message = try #require(regular.message(for: textRow(answer), version: 0))
      let small = try #require(regular.measuredHeight(of: message, width: textRowWidth))
      let largeMessage = try #require(large.message(for: textRow(answer), version: 0))
      let big = try #require(large.measuredHeight(of: largeMessage, width: textRowWidth))
      #expect(big > small + 20)
    }

    @Test("Messages asked for ahead build and draw off the main actor; offered ones only lay out")
    func prewarm() async throws {
      let rasters = MessageTextRasters(byteLimit: 64 << 20)
      let sizes = MessageTextSizes(limit: 64)
      let prewarm = MessageTextRunPrewarm(limit: 8, workers: 2, rasters: rasters, sizes: sizes)
      let style = textRowStyle()
      let palette = try #require(style.palette)
      let rasterStyle = try #require(style.rasterStyle)
      prewarm.note(
        MessageTextRunPrewarm.Context(palette: palette, width: 300, scale: 2, raster: rasterStyle))
      let wanted = "Drawn **ahead** of the scroll."
      let offered = "Only laid out."
      prewarm.prioritize([wanted], at: [0])
      prewarm.offer(offered)
      func document(_ text: String) -> MessageTextDocument? {
        prewarm.document(
          for: MessageTextDocumentKey(
            text: text, piece: 0, style: palette.style, linked: [], math: []))
      }
      for _ in 0..<200 {
        if let drawn = document(wanted), let laid = document(offered),
          rasters.contains(MessageTextRasterKey(document: drawn.serial, width: 300, scale: 2)),
          sizes.size(document: laid.serial, width: 300) != nil
        {
          break
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      let drawn = try #require(document(wanted))
      let laid = try #require(document(offered))
      #expect(rasters.contains(MessageTextRasterKey(document: drawn.serial, width: 300, scale: 2)))
      #expect(sizes.size(document: drawn.serial, width: 300) != nil)
      #expect(!rasters.contains(MessageTextRasterKey(document: laid.serial, width: 300, scale: 2)))
      #expect(sizes.size(document: laid.serial, width: 300) != nil)
    }

    // MARK: In the collection

    private struct Host: View {
      let conversation: LiveConversation

      var body: some View {
        TableTranscriptView(
          state: conversation.state, liveRows: nil, actions: ConversationActions(),
          scrollToLatestRequest: conversation.scrollRequest
        )
        .environment(\.messageTextRenderer, .textKit)
        .environment(\.layoutWidth, .compact)
      }
    }

    private func screen(_ conversation: LiveConversation) async throws
      -> (InProcessWindow, TranscriptCollectionController)
    {
      let window = try InProcessWindow(
        Host(conversation: conversation), width: textRowWidth, height: 852)
      await window.settle(.milliseconds(300))
      let list = try #require(
        window.views(UICollectionView.self).first { $0.delegate is TranscriptCollectionController })
      let controller = try #require(list.delegate as? TranscriptCollectionController)
      return (window, controller)
    }

    @Test("In the list, settled messages show in text rows at their measured heights")
    func inTheList() async throws {
      let conversation = collectionSession()
      let (window, controller) = try await screen(conversation)
      defer { window.close() }
      var text = 0
      for case let cell as TranscriptCollectionCell in controller.collectionView.visibleCells {
        guard let host = cell.host, let id = host.shownID,
          let measured = controller.model.heights.measurement(of: id)
        else { continue }
        #expect(abs(cell.bounds.height - measured.height) < 1, "\(id)")
        if id == "a-last" {
          // The latest answer keeps its action row, in SwiftUI.
          #expect(host is TranscriptCollectionRowHost)
        } else if id.hasPrefix("a") || id.hasPrefix("u") {
          #expect(host is TranscriptCollectionTextView, "\(id)")
          text += 1
        }
      }
      #expect(text >= 2)
      #expect(controller.textViewsMade >= text)
    }

    @Test("An answer that settles leaves SwiftUI for a text row once the next turn starts")
    func settlesIntoText() async throws {
      let conversation = collectionSession()
      let (window, controller) = try await screen(conversation)
      defer { window.close() }
      func host(_ id: String) -> (any TranscriptCollectionRowView)? {
        controller.model.index(of: id).flatMap(controller.realizedHost(at:))
      }
      #expect(host("a-last") is TranscriptCollectionRowHost)
      conversation.append(
        TranscriptFixture.user("u-next", "Next?"),
        TranscriptFixture.answer("a-next", "Sure.", responseID: "r-next"))
      await window.settle(.milliseconds(300))
      #expect(host("a-last") is TranscriptCollectionTextView)
      #expect(host("a-next") is TranscriptCollectionRowHost)
      let index = try #require(controller.model.index(of: "a-last"))
      let cell = try #require(
        controller.collectionView.cellForItem(at: IndexPath(item: index, section: 0)))
      let measured = try #require(controller.model.heights.measurement(of: "a-last"))
      #expect(abs(cell.bounds.height - measured.height) < 1)
    }

    @Test("Turning the window draws the rows on screen at the new width off the main thread")
    func rotationDrawsAhead() async throws {
      let conversation = collectionSession(turns: 16)
      // Text of its own: the drawings other suites turn to the same width are kept process-wide.
      let marker = UUID().uuidString
      for index in conversation.state.rows.indices {
        conversation.state.rows[index].text += " \(marker)"
      }
      let (window, controller) = try await screen(conversation)
      defer { window.close() }
      let list = controller.collectionView
      controller.scrollViewWillBeginDragging(list)
      list.contentOffset.y -= 1400
      list.layoutIfNeeded()
      controller.scrollViewDidEndDragging(list, willDecelerate: false)
      // Idle measuring and the prewarm reach the rows around the reader.
      await window.settle(.milliseconds(900))
      let anchor = try #require(controller.readingAnchor())
      let drawn = controller.textStyle.drawnNow
      func textViews() -> [TranscriptCollectionTextView] {
        list.visibleCells.compactMap {
          ($0 as? TranscriptCollectionCell)?.host as? TranscriptCollectionTextView
        }
      }
      window.window.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
      window.window.layoutIfNeeded()
      list.layoutIfNeeded()
      // The pass that took the width drew nothing: the rows show their old drawings, fitted.
      #expect(controller.textStyle.drawnNow == drawn)
      let turned = textViews()
      #expect(!turned.isEmpty)
      #expect(turned.allSatisfy { $0.runView?.image.showsDrawing == true })
      #expect(turned.contains { $0.awaitedWidth != nil })
      for _ in 0..<50 where textViews().contains(where: { $0.awaitedWidth != nil }) {
        await window.settle(.milliseconds(40))
      }
      for view in textViews() {
        let message = try #require(view.message)
        let run = try #require(view.runView)
        #expect(view.awaitedWidth == nil)
        let width = controller.textStyle.textWidth(of: message, width: controller.model.width)
        #expect(run.raster.width == width)
        #expect(run.transform == .identity)
        #expect(run.image.showsDrawing)
      }
      #expect(controller.readingAnchor()?.id == anchor.id)
    }
  }
#endif
