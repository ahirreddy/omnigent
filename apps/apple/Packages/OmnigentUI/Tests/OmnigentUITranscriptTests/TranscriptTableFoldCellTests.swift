#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// Worked folds and an empty header or footer drawn in AppKit cells in the table transcript:
  /// they size as SwiftUI's rows do, a fold opens and closes as SwiftUI's does, and the reader's
  /// choice outlasts the cell.
  @Suite("Transcript table fold cells", .serialized)
  @MainActor
  struct TranscriptTableFoldCellTests {
    static let width: CGFloat = 900

    init() {
      SystemSideEffects.reset()
    }

    private struct Host: View {
      let conversation: LiveConversation

      var body: some View {
        TableTranscriptView(
          state: conversation.state, liveRows: nil, actions: ConversationActions(),
          scrollToLatestRequest: conversation.scrollRequest)
      }
    }

    private func environment(labelSize: CGFloat = TypeRamp.defaultBody)
      -> TranscriptTableEnvironment
    {
      let environment = TranscriptTableEnvironment()
      var values = EnvironmentValues()
      values.typeRamp = TypeRamp(body: labelSize)
      environment.values = values
      return environment
    }

    private func style(_ environment: TranscriptTableEnvironment) -> TranscriptTableTextStyle {
      let style = TranscriptTableTextStyle(environment: environment)
      style.refresh()
      return style
    }

    /// Fold `id`'s two steps; the reader's choice is kept by the first one's id.
    private static func steps(_ id: String) -> [TranscriptItem] {
      [
        .activity(TranscriptFixture.activityRow(.error, id: "\(id)-step-1", title: "A step")),
        .activity(
          TranscriptFixture.activityRow(.error, id: "\(id)-step-2", title: "Another step")),
      ]
    }

    private func fold(_ id: String = "f1", isLive: Bool = false) -> TranscriptTableRow {
      TranscriptTableRow(
        .segment(
          SegmentEntry(
            segment: .worked(id: id, responseID: "r1", items: Self.steps(id), isLive: isLive),
            decorations: [:], duration: 12)))
    }

    /// The height SwiftUI's row gives `row` in a hosted cell.
    private func hostedHeight(
      _ row: TranscriptTableRow, _ environment: TranscriptTableEnvironment
    ) -> CGFloat {
      let cell = TranscriptTableHostingCell.make(environment: environment)
      cell.show(row, version: 0, width: Self.width)
      return cell.idealHeight
    }

    @Test("A closed fold is as tall as SwiftUI's at each label size, an open one as well")
    func sizing() {
      for size in [TypeRamp.defaultBody, 20] {
        let environment = environment(labelSize: size)
        let cell = TranscriptTableFoldCell(
          style: style(environment), folds: TranscriptTableFolds(disclosures: .init()))
        cell.show(fold(), version: 0, width: Self.width)
        #expect(!cell.isExpanded)
        #expect(cell.itemsView == nil, "a closed fold hosts nothing")
        #expect(cell.idealHeight == hostedHeight(fold(), environment), "label size \(size)")
        cell.show(fold("f-live", isLive: true), version: 0, width: Self.width)
        #expect(cell.isExpanded, "open while its turn is live")
        #expect(
          cell.idealHeight == hostedHeight(fold("f-live", isLive: true), environment),
          "label size \(size), open")
      }
    }

    @Test("A SwiftUI row fitted without constraints is as tall as one sized by Auto Layout")
    func fitted() {
      let environment = environment()
      let activity = TranscriptTableRow(
        .segment(
          SegmentEntry(
            segment: .item(
              .activity(TranscriptFixture.activityRow(.error, id: "e1", title: "A failure"))),
            decorations: [:], duration: nil)))
      for row in [fold(), fold("f-live", isLive: true), activity] {
        let cell = TranscriptTableFittedCell(environment: environment)
        cell.show(row, version: 0, width: Self.width)
        #expect(cell.idealHeight == hostedHeight(row, environment), "\(row.id)")
      }
    }

    @Test("A press opens and closes the fold, and the reader's choice outlasts the cell")
    func toggles() throws {
      let environment = environment()
      let disclosures = TranscriptDisclosures()
      let folds = TranscriptTableFolds(disclosures: disclosures)
      let cell = TranscriptTableFoldCell(style: style(environment), folds: folds)
      var reports = 0
      cell.idealSizeChanged = { _ in reports += 1 }
      cell.show(fold(), version: 0, width: Self.width)
      let closed = cell.idealHeight
      let button = cell.button
      #expect(button.accessibilityRole() == .button)
      #expect(button.accessibilityLabel() == "2 steps")
      #expect(button.accessibilityIdentifier() == "worked-fold-f1-step-1")
      #expect(button.accessibilityValue() as? String == "Collapsed")
      #expect(button.toolTip == "Worked for 12s")
      #expect(button.accessibilityPerformPress())
      #expect(cell.isExpanded)
      #expect(button.accessibilityValue() as? String == "Expanded")
      // Kept where SwiftUI's fold reads it.
      #expect(disclosures.choice("worked-f1-step-1").isExpanded == true)
      #expect(reports == 1)
      let open = cell.idealHeight
      #expect(open > closed)
      #expect(try #require(cell.itemsView).frame.height > 0)
      // The cell shows another fold, then this one again: still open.
      cell.show(fold("f2"), version: 0, width: Self.width)
      #expect(!cell.isExpanded)
      #expect(cell.idealHeight == closed)
      cell.show(fold(), version: 0, width: Self.width)
      #expect(cell.isExpanded)
      #expect(cell.idealHeight == open)
      #expect(button.accessibilityPerformPress())
      #expect(!cell.isExpanded)
      #expect(cell.itemsView == nil)
      #expect(cell.idealHeight == closed)
    }

    @Test("In the table, folds and an empty footer take AppKit cells at their measured height")
    func cellKinds() async throws {
      let rows = [
        TranscriptFixture.user("u1", "Short?"),
        TranscriptFixture.toolCall("t1"),
        TranscriptFixture.answer("a1", "Yes.", responseID: "resp-1"),
      ]
      let conversation = LiveConversation(
        ConversationViewState(header: TranscriptFixture.header, rows: rows))
      let window = transcriptScreen(
        Host(conversation: conversation), width: Self.width, height: 900)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 200)
      let driver = TranscriptScrollDriver(screen: window)
      let table = try #require(driver.scrollView?.documentView as? NSTableView)
      let controller = try #require(table.delegate as? TranscriptTableController)
      let foldIndex = try #require(controller.model.rows.firstIndex { $0.kind == .worked })
      let footer = try #require(controller.model.index(of: TranscriptTableRow.footerID))
      for index in [foldIndex, footer] {
        let kind = controller.cellKind(at: index)
        guard case .native = kind else {
          Issue.record("row \(index) is \(kind)")
          continue
        }
        let cell = try #require(controller.realizedCell(at: index), "row \(index) is on screen")
        #expect(cell.kind == kind)
        #expect(controller.model.height(at: index) == cell.idealHeight)
      }
      let cell = try #require(
        controller.realizedCell(at: foldIndex) as? TranscriptTableFoldCell)
      let closed = table.rect(ofRow: foldIndex).height
      #expect(cell.button.accessibilityPerformPress())
      window.settle()
      #expect(table.rect(ofRow: foldIndex).height > closed, "the table took the open height")
      #expect(controller.model.height(at: foldIndex) == cell.idealHeight)
    }
  }
#endif
