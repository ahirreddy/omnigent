import Foundation
import Testing

@testable import OmnigentUIComponents
@testable import OmnigentUITestSupport

/// The table transcript's rows and heights, without AppKit.
@Suite("Transcript table model")
@MainActor
struct TranscriptTableModelTests {
  private func rows(_ state: ConversationViewState) -> [TranscriptTableRow] {
    TranscriptTableRow.rows(
      for: state, layout: .chat(TranscriptLayoutMemo().entries(for: state)), offersOlder: true)
  }

  private func state(turns: Int, startingAt first: Int = 0) -> ConversationViewState {
    ConversationViewState(
      header: TranscriptFixture.header, rows: TranscriptFixture.turns(turns, startingAt: first))
  }

  @Test("A row is measured once per content version and width")
  func heightsPerVersionAndWidth() throws {
    var model = TranscriptTableModel()
    var conversation = state(turns: 2)
    _ = model.replaceRows(rows(conversation))
    let widened = model.setWidth(600)
    #expect(widened)
    let answer = try #require(model.index(of: "a1"))
    #expect(model.needsMeasure(at: answer))
    let estimate = model.provideHeight(at: answer)

    // The table was given the estimate, so a measured height that differs needs a note.
    let differs = model.record(estimate + 80, at: answer)
    #expect(differs)
    #expect(!model.needsMeasure(at: answer))
    #expect(model.height(at: answer) == estimate + 80)
    _ = model.provideHeight(at: answer)
    let differsAgain = model.record(estimate + 80, at: answer)
    #expect(!differsAgain)

    // New content under the same id: measured again, the old height standing in until then.
    conversation.rows[3].text += "\n\nOne more paragraph"
    let change = model.replaceRows(rows(conversation))
    #expect(change.changed == [answer])
    #expect(change.inserted.isEmpty && change.removed.isEmpty)
    #expect(model.needsMeasure(at: answer))
    #expect(model.height(at: answer) == estimate + 80)
    let question = try #require(model.index(of: "u1"))
    model.record(40, at: question)

    // Another width: every row is measured again.
    let nudged = model.setWidth(600.2)
    #expect(!nudged)
    let narrowed = model.setWidth(480)
    #expect(narrowed)
    #expect(model.needsMeasure(at: question))
    #expect(model.height(at: question) == 40)
  }

  @Test("Rows are matched by id from both ends")
  func changesByID() {
    var model = TranscriptTableModel()
    _ = model.replaceRows(rows(state(turns: 3, startingAt: 5)))
    // A page of history lands above.
    let paged = model.replaceRows(rows(state(turns: 5, startingAt: 3)))
    #expect(paged.removed == 1..<1)
    #expect(paged.inserted == 1..<5)
    // A turn is added at the end; the footer and the last answer's actions stay.
    var grown = state(turns: 6, startingAt: 3)
    grown.rows.removeLast()
    let appended = model.replaceRows(rows(grown))
    #expect(appended.removed.isEmpty)
    #expect(appended.inserted == 11..<12)
  }

  @Test("Estimates follow the heights measured for their kind")
  func calibratedEstimates() throws {
    var model = TranscriptTableModel()
    _ = model.replaceRows(rows(state(turns: 3)))
    _ = model.setWidth(600)
    let first = try #require(model.index(of: "a0"))
    let second = try #require(model.index(of: "a1"))
    let estimate = model.height(at: second)
    model.record(model.height(at: first) * 2, at: first)
    #expect(abs(model.height(at: second) - estimate * 2) <= 1)
    #expect(model.needsMeasure(at: second))
  }

  @Test("A row keeps the height the list was given while its kind's estimates move")
  func givenHeightsStay() throws {
    var model = TranscriptTableModel()
    _ = model.replaceRows(rows(state(turns: 3)))
    _ = model.setWidth(600)
    let far = try #require(model.index(of: "a0"))
    let given = model.givenHeight(at: far)
    let near = try #require(model.index(of: "a2"))
    model.record(model.height(at: near) * 3, at: near)
    #expect(model.height(at: far) > given * 2)
    #expect(model.givenHeight(at: far) == given)
    let fresh = try #require(model.index(of: "u0"))
    #expect(model.givenHeight(at: fresh) == model.height(at: fresh))
  }

  @Test("A new text size measures every row again, the old heights standing in")
  func heightsInvalidated() throws {
    var model = TranscriptTableModel()
    _ = model.replaceRows(rows(state(turns: 2)))
    _ = model.setWidth(600)
    for index in model.rows.indices { model.record(100, at: index) }
    let answer = try #require(model.index(of: "a1"))
    let version = model.version(at: answer)
    model.invalidateHeights()
    #expect(model.rows.indices.allSatisfy { model.needsMeasure(at: $0) })
    #expect(model.version(at: answer) == version + 1)
    #expect(model.height(at: answer) == 100)
  }

  @Test("Rows stack at their heights; a change lays out only the rows from it down")
  func rowOffsets() {
    var offsets = TranscriptRowOffsets()
    #expect(offsets.row(at: 10) == nil)
    #expect(offsets.rows(from: 0, to: 100).isEmpty)
    var heights: [CGFloat] = [10, 20, 30, 40]
    offsets.rebuild(count: heights.count) { heights[$0] }
    #expect(offsets.contentHeight == 100)
    #expect(offsets.top(of: 2) == 30)
    #expect(offsets.height(of: 3) == 40)
    #expect(offsets.row(at: -5) == 0)
    #expect(offsets.row(at: 30) == 2)
    #expect(offsets.row(at: 29.5) == 1)
    #expect(offsets.row(at: 500) == 3)
    #expect(offsets.rows(from: 15, to: 30) == 1..<2)
    #expect(offsets.rows(from: 15, to: 31) == 1..<3)
    #expect(offsets.rows(from: -50, to: 0).isEmpty)
    #expect(offsets.rows(from: 100, to: 200).isEmpty)
    #expect(offsets.rows(from: 90, to: 200) == 3..<4)
    heights[1] = 70
    offsets.update(from: 1) { heights[$0] }
    #expect(offsets.top(of: 1) == 10)
    #expect(offsets.top(of: 3) == 110)
    #expect(offsets.contentHeight == 150)
  }

  @Test("Rows that leave forget their heights")
  func removedRowsForget() throws {
    var model = TranscriptTableModel()
    _ = model.replaceRows(rows(state(turns: 2)))
    _ = model.setWidth(600)
    let answer = try #require(model.index(of: "a0"))
    model.record(300, at: answer)
    _ = model.replaceRows(rows(state(turns: 1, startingAt: 1)))
    #expect(model.index(of: "a0") == nil)
    #expect(model.heights.measurement(of: "a0") == nil)
    _ = model.replaceRows(rows(state(turns: 2)))
    let back = try #require(model.index(of: "a0"))
    #expect(model.needsMeasure(at: back))
  }

  @Test("The header and footer carry what they show, and only that")
  func headerAndFooter() {
    var conversation = state(turns: 1)
    conversation.hasMoreHistory = true
    conversation.header.status = .running
    let built = rows(conversation)
    #expect(built.first?.id == TranscriptTableRow.headerID)
    #expect(built.last?.id == TranscriptTableRow.footerID)
    guard case .header(let header) = built.first?.content,
      case .footer(let footer) = built.last?.content
    else {
      Issue.record("no header or footer")
      return
    }
    #expect(header.history == .offersOlder)
    #expect(header.empty == nil)
    #expect(footer.working?.isBlocked == false)
    // A streamed delta changes the answer's row, not the footer's.
    var streamed = conversation
    streamed.rows[1].isStreaming = true
    streamed.rows[1].text += " more"
    streamed.revision += 1
    let next = rows(streamed)
    #expect(next.last?.content != built.last?.content)
    streamed.rows[1].text += " and more"
    #expect(rows(streamed).last?.content == next.last?.content)
  }
}
