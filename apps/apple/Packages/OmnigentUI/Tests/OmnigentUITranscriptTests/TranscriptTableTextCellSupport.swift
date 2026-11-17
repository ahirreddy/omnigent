#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The width the text cell suites lay rows out at.
  let textCellWidth: CGFloat = 900

  /// The table transcript with the TextKit renderer, in an environment the test adds to.
  struct TextCellTableHost: View {
    let conversation: LiveConversation
    var actions = ConversationActions()
    var environment: (inout EnvironmentValues) -> Void = { _ in }

    var body: some View {
      TableTranscriptView(
        state: conversation.state, liveRows: nil, actions: actions,
        scrollToLatestRequest: conversation.scrollRequest
      )
      .environment(\.messageTextRenderer, .textKit)
      .transformEnvironment(\.self, transform: environment)
    }
  }

  /// The table transcript showing `rows`, opened.
  @MainActor
  func textTableScreen(
    _ rows: [Row], actions: ConversationActions = ConversationActions(),
    environment: @escaping (inout EnvironmentValues) -> Void = { _ in }
  ) async throws -> OffscreenWindow<AnyView> {
    let conversation = LiveConversation(
      ConversationViewState(header: TranscriptFixture.header, rows: rows))
    let screen = transcriptScreen(
      TextCellTableHost(conversation: conversation, actions: actions, environment: environment),
      actions: actions, width: textCellWidth, height: 900)
    try await letTasksRun(screen, milliseconds: 200)
    return screen
  }

  /// The controller of the table transcript on `screen`.
  @MainActor
  func tableController(of screen: OffscreenWindow<AnyView>) throws -> TranscriptTableController {
    let driver = TranscriptScrollDriver(screen: screen)
    let table = try #require(driver.scrollView?.documentView as? NSTableView)
    return try #require(table.delegate as? TranscriptTableController)
  }

  /// The text cell showing row `id` on `screen`.
  @MainActor
  func textCell(_ id: String, in screen: OffscreenWindow<AnyView>) throws
    -> TranscriptTableTextCell
  {
    let controller = try tableController(of: screen)
    let index = try #require(controller.model.index(of: id), "\(id) is a row")
    return try #require(
      controller.realizedCell(at: index) as? TranscriptTableTextCell, "\(id) is a text cell")
  }

  /// Scrolls `screen`'s transcript so `view`, in one of its rows, is in the middle of it.
  @MainActor
  func scrollToShow(_ view: NSView, in screen: OffscreenWindow<AnyView>) throws {
    let driver = TranscriptScrollDriver(screen: screen)
    let scrollView = try #require(driver.scrollView)
    let document = try #require(scrollView.documentView)
    let frame = view.convert(view.bounds, to: document)
    driver.move(to: frame.midY - scrollView.contentView.bounds.height / 2)
  }

  /// A chat environment with the TextKit renderer, which the test adds to.
  @MainActor
  func textCellEnvironment(_ transform: (inout EnvironmentValues) -> Void = { _ in })
    -> TranscriptTableEnvironment
  {
    let environment = TranscriptTableEnvironment()
    var values = EnvironmentValues()
    values.messageTextRenderer = .textKit
    transform(&values)
    environment.values = values
    return environment
  }

  /// The style text cells draw in, read from `environment`.
  @MainActor
  func textCellStyle(_ environment: TranscriptTableEnvironment) -> TranscriptTableTextStyle {
    let style = TranscriptTableTextStyle(environment: environment)
    style.refresh()
    return style
  }

  /// A table row showing `message` with `decoration`.
  @MainActor
  func textCellRow(_ message: Row, decoration: MessageDecoration = MessageDecoration())
    -> TranscriptTableRow
  {
    TranscriptTableRow(
      .segment(
        SegmentEntry(
          segment: .item(.message(message)), decorations: [message.id: decoration],
          duration: nil)))
  }

  /// The height SwiftUI's row gives `row` in a hosted cell.
  @MainActor
  func hostedRowHeight(_ row: TranscriptTableRow, _ environment: TranscriptTableEnvironment)
    -> CGFloat
  {
    let cell = TranscriptTableHostingCell.make(environment: environment)
    cell.show(row, version: 0, width: textCellWidth)
    return cell.idealHeight
  }

  /// `message`'s height far from view, from its runs' and hosted parts' sizes.
  @MainActor
  func farRowHeight(_ message: TranscriptTableTextMessage, _ style: TranscriptTableTextStyle)
    throws -> CGFloat
  {
    try #require(
      TranscriptTableTextCell.measuredHeight(
        of: message, style: style, width: textCellWidth,
        blockHeight: { block, piece, width in
          let view = TranscriptTableBlockView.make(environment: style.environment)
          view.show(block, piece: piece, width: width)
          return view.idealHeight
        }))
  }

  /// Shows `row` in a new text cell, which must take it, and checks it is as tall as SwiftUI's
  /// row and as a far row measures.
  @MainActor
  func shownMatchingSwiftUI(
    _ row: TranscriptTableRow, _ environment: TranscriptTableEnvironment,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws -> TranscriptTableTextCell {
    let style = textCellStyle(environment)
    let cell = TranscriptTableTextCell(style: style)
    cell.show(row, version: 0, width: textCellWidth)
    let message = try #require(
      cell.message, "\(row.id) takes a text cell", sourceLocation: sourceLocation)
    #expect(
      cell.idealHeight == hostedRowHeight(row, environment), "\(row.id) is as tall as SwiftUI's",
      sourceLocation: sourceLocation)
    #expect(
      try farRowHeight(message, style) == cell.idealHeight, "\(row.id) measures as it shows",
      sourceLocation: sourceLocation)
    return cell
  }
#endif
