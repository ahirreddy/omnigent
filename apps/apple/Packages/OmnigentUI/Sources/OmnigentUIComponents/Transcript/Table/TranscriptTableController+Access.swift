#if os(macOS)
  import AppKit
  import SwiftUI

  extension TranscriptTableController {
    // MARK: Keyboard

    /// How far an arrow key scrolls.
    static let keyLine: CGFloat = 40

    /// Scrolls for a key a row passed on, as the reader's own step: an arrow a line, Page Up
    /// and Down and Space (Shift-Space up) a page, Home and End to the ends.
    /// - Returns: Whether the key scrolls the transcript.
    func scrolls(for event: NSEvent) -> Bool {
      let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
      guard let key = event.charactersIgnoringModifiers?.utf16.first.map(Int.init) else {
        return false
      }
      let offset = clipView.bounds.minY
      let page = max(Self.keyLine, visibleHeight - Self.keyLine)
      let target: CGFloat
      switch (key, modifiers) {
      case (NSUpArrowFunctionKey, []): target = offset - Self.keyLine
      case (NSDownArrowFunctionKey, []): target = offset + Self.keyLine
      case (NSPageUpFunctionKey, []), (0x20, .shift): target = offset - page
      case (NSPageDownFunctionKey, []), (0x20, []): target = offset + page
      case (NSHomeFunctionKey, []):
        readerScrolled()
        moveToTop()
        return true
      case (NSEndFunctionKey, []):
        measureEnd()
        target = maximumOffset
      default: return typesIntoComposer(event)
      }
      // The follow rules take it as a step of the reader's wheel.
      readerScrolled()
      move(to: target)
      return true
    }

    /// A printable key without a chord, other than Space, starts a message: the composer takes
    /// focus and the character, as the web's `useTypeToComposer`.
    /// - Returns: Whether the composer took it.
    func typesIntoComposer(_ event: NSEvent) -> Bool {
      guard let type = actions.typeIntoComposer,
        event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
        let characters = event.characters, characters.count == 1, characters != " ",
        let scalar = characters.unicodeScalars.first, scalar.value < 0xF700,
        !CharacterSet.controlCharacters.contains(scalar)
      else { return false }
      type(characters)
      return true
    }

    // MARK: Assistive clients

    /// What an assistive client reads of the rows, top to bottom: the elements of the rows the
    /// table shows, and while one reads the window, a text element for each row it does not,
    /// as the stack lays out every row for one.
    func accessibilityRows() -> [Any] {
      // Only an assistive client asks: the rows on screen take elements made with it there.
      if !isReadByAssistiveClient { setReadByAssistiveClient(true) }
      var elements: [Any] = []
      for (index, row) in model.rows.enumerated() {
        if let cell = realizedCell(at: index) {
          // AppKit's helper is not annotated for memory safety; the cell is alive for the call.
          elements += unsafe NSAccessibility.unignoredChildren(from: [cell])
        } else if isReadByAssistiveClient, let text = row.accessibilityText {
          elements.append(rowElement(row.id, text: text))
        }
      }
      return elements
    }

    /// The element standing in for a row the table has not laid out.
    func rowElement(_ id: String, text: String) -> TranscriptRowElement {
      if let element = rowElements[id], element.text == text { return element }
      let element = TranscriptRowElement(
        controller: self, table: tableView, rowID: id, text: text)
      rowElements[id] = element
      return element
    }

    /// Where row `id` is on the screen, for its stand-in element.
    func screenFrame(of id: String) -> NSRect {
      guard let index = model.index(of: id), index < tableView.numberOfRows,
        let window = unsafe tableView.window
      else { return .zero }
      let rect = tableView.convert(tableView.rect(ofRow: index), to: nil)
      return window.convertToScreen(rect)
    }

    /// An assistive client reads the window, or stopped. While one reads, the rows the table
    /// has not laid out are read through stand-ins (``TranscriptRowElement``), as the stack lays
    /// out every row for one.
    func setReadByAssistiveClient(_ isRead: Bool) {
      guard isRead != isReadByAssistiveClient else { return }
      isReadByAssistiveClient = isRead
      probe("transcript assistive client", "\(isRead)")
      if isRead {
        AssistiveClientNotice.write()
        // Cells made before a client read the window have no elements: the rows on screen
        // take new ones, made with the client there.
        let shown = tableView.rows(in: tableView.visibleRect)
        if shown.length > 0 {
          tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: shown.location..<(shown.location + shown.length)),
            columnIndexes: [0])
        }
      } else {
        rowElements = [:]
      }
      rowsChangedForAssistiveClient()
    }

    /// Tells an assistive client the rows it reads changed.
    func rowsChangedForAssistiveClient() {
      // AppKit's poster is not annotated for memory safety; the table outlives the call.
      unsafe NSAccessibility.post(element: tableView, notification: .layoutChanged)
    }
  }
#endif

#if os(macOS)
  /// A row the table has not laid out, as an assistive client reads it: its text, where the
  /// row is, and the transcript as its parent. Scrolled into view, the row's own elements take
  /// its place.
  nonisolated final class TranscriptRowElement: NSAccessibilityElement {
    weak var controller: TranscriptTableController?
    /// The transcript's table, which reads the rows.
    weak var table: NSView?
    let rowID: String
    let text: String

    init(controller: TranscriptTableController, table: NSView, rowID: String, text: String) {
      self.controller = controller
      self.table = table
      self.rowID = rowID
      self.text = text
      super.init()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { text }
    override func accessibilityIdentifier() -> String { "transcript-row-\(rowID)" }
    override func accessibilityParent() -> Any? { table }

    // Assistive clients ask on the main thread.
    override func accessibilityFrame() -> NSRect {
      let controller = controller
      let id = rowID
      return MainActor.assumeIsolated { controller?.screenFrame(of: id) ?? .zero }
    }
  }

  extension TranscriptTableRow {
    /// What an assistive client reads of the row while the table has not laid it out: its
    /// messages' and activities' text; `nil` for the header and footer.
    var accessibilityText: String? {
      switch content {
      case .header, .footer: nil
      case .segment(let entry): Self.text(of: entry.segment)
      case .block(let entry):
        switch entry.block {
        case .segment(let segment): Self.text(of: segment)
        case .footer(_, let text): text
        }
      }
    }

    private static func text(of segment: TurnSegment) -> String {
      switch segment {
      case .item(let item): text(of: item)
      case .worked(_, _, let items, _): items.map(text(of:)).joined(separator: "\n")
      }
    }

    private static func text(of item: TranscriptItem) -> String {
      switch item {
      case .message(let row): row.text
      case .activity(let row):
        [row.activity?.title, row.activity?.summary, row.text].compactMap(\.self)
          .filter { !$0.isEmpty }.joined(separator: ", ")
      case .tools(_, let entries):
        entries.compactMap { $0.primary?.activity.map { "\($0.title) \($0.summary)" } }
          .joined(separator: "\n")
      }
    }
  }
#endif
