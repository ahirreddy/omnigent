#if canImport(AppKit)
  import AppKit
#else
  import UIKit
#endif

/// One accessibility element of a message's text, as SwiftUI exposes ``MarkdownView``'s: a
/// heading, a paragraph with its links, a list's number or task box, a code block with its label
/// and code, or a table with its cells. Bullets, quote bars and rules read as nothing.
nonisolated struct MessageTextAccessibilityItem: Equatable {
  enum Role: Equatable {
    case heading(level: Int)
    case text
    case link(URL)
    case image
    /// A code block, by its block; its controls go between its label and its code.
    case codeBlock(block: Int)
    /// A table, by its block; its controls follow it.
    case table(block: Int)
  }

  var role: Role
  var label: String?
  var value: String?
  /// Where it is in the text, for its frame.
  var range: NSRange
  var children: [Self] = []

  /// The elements of `text`, in reading order; `chrome` names each code block's language.
  static func items(in text: NSAttributedString, chrome: [Int: MessageTextChrome])
    -> [Self]
  {
    var items: [Self] = []
    for paragraph in paragraphs(in: text) {
      // Nothing reads the effective range back.
      let mark =
        unsafe text.attribute(.messageBlock, at: paragraph.location, effectiveRange: nil)
        as? MessageBlockMark
      switch mark?.role {
      case .codeHeader:
        let language = mark.flatMap { chrome[$0.block] }.flatMap { chrome -> String? in
          if case .code(_, let language) = chrome { return CodeLanguageName.label(for: language) }
          return nil
        }
        items.append(
          Self(
            role: .codeBlock(block: mark?.block ?? 0), label: "Code block, \(language ?? "")",
            range: paragraph,
            children: [
              Self(role: .text, value: language, range: paragraph)
            ]))
      case .codeLine:
        guard var block = items.last, case .codeBlock = block.role else { continue }
        let line = text.messageCopyText(in: paragraph)
        if block.children.count < 2 {
          block.children.append(
            Self(role: .text, value: line, range: paragraph))
        } else {
          block.children[1].value = (block.children[1].value ?? "") + "\n" + line
          block.children[1].range = NSUnionRange(block.children[1].range, paragraph)
        }
        block.range = NSUnionRange(block.range, paragraph)
        items[items.count - 1] = block
      case .tableRow:
        let cells = Self.cells(in: paragraph, of: text)
        if let block = mark?.block, var table = items.last, table.role == .table(block: block) {
          table.children += cells
          table.range = NSUnionRange(table.range, paragraph)
          items[items.count - 1] = table
        } else {
          items.append(
            Self(
              role: .table(block: mark?.block ?? 0), range: paragraph, children: cells))
        }
      case .rule:
        continue
      case nil:
        items += prose(in: paragraph, of: text)
      }
    }
    return items
  }

  /// Each paragraph's range in `text`, without its line break.
  private static func paragraphs(in text: NSAttributedString) -> [NSRange] {
    var ranges: [NSRange] = []
    var start = 0
    for (offset, unit) in text.string.utf16.enumerated() where unit == 0x0A {
      ranges.append(NSRange(location: start, length: offset - start))
      start = offset + 1
    }
    if start < text.length { ranges.append(NSRange(location: start, length: text.length - start)) }
    return ranges
  }

  /// A paragraph or heading, after its list marker if it has one.
  private static func prose(in paragraph: NSRange, of text: NSAttributedString)
    -> [Self]
  {
    var items: [Self] = []
    var content = paragraph
    let string = text.attributedSubstring(from: paragraph).string
    if string.hasPrefix("\t"), let second = string.dropFirst().firstIndex(of: "\t") {
      let markerLength = string.utf16.distance(from: string.startIndex, to: second) - 1
      let marker = NSRange(location: paragraph.location + 1, length: markerLength)
      // Nothing reads the effective range back.
      let mark =
        unsafe text.attribute(.messageAccessibility, at: marker.location, effectiveRange: nil)
        as? MessageAccessibilityMark
      switch mark?.kind {
      case .number(let number):
        items.append(Self(role: .text, value: number, range: marker))
      case .task(let label):
        items.append(Self(role: .image, label: label, range: marker))
      case .bullet, .heading, nil:
        break
      }
      let skipped = markerLength + 2
      content = NSRange(location: paragraph.location + skipped, length: paragraph.length - skipped)
    }
    let value = text.messageCopyText(in: content)
    guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
    // Nothing reads the effective range back.
    let heading =
      unsafe text.attribute(.messageAccessibility, at: content.location, effectiveRange: nil)
      as? MessageAccessibilityMark
    if case .heading(let level)? = heading?.kind {
      items.append(
        Self(
          role: .heading(level: level), label: value, value: value, range: content))
      return items
    }
    let links = MessageTextDocument.links(in: text.attributedSubstring(from: content)).map {
      Self(
        role: .link($0.url), label: text.messageCopyText(in: shifted($0.range, by: content)),
        range: shifted($0.range, by: content))
    }
    items.append(
      Self(role: .text, value: value, range: content, children: links))
    return items
  }

  private static func shifted(_ range: NSRange, by base: NSRange) -> NSRange {
    NSRange(location: base.location + range.location, length: range.length)
  }

  /// A table row's cells, split at its tabs; an empty cell reads as nothing.
  private static func cells(in row: NSRange, of text: NSAttributedString)
    -> [Self]
  {
    let units = Array(text.attributedSubstring(from: row).string.utf16)
    // A row whose first column isn't leading starts with a tab to it.
    var start = units.first == 0x09 ? 1 : 0
    var cells: [Self] = []
    for index in start...units.count where index == units.count || units[index] == 0x09 {
      let cell = NSRange(location: row.location + start, length: index - start)
      if cell.length > 0 {
        cells.append(
          Self(
            role: .text, value: text.messageCopyText(in: cell), range: cell))
      }
      start = index + 1
    }
    return cells
  }
}

#if os(macOS)
  /// One element of a message's text on the Mac, its frame where the text laid it out.
  nonisolated final class MessageTextAccessibilityElement: NSAccessibilityElement,
    NSAccessibilityElementProtocol
  {
    let item: MessageTextAccessibilityItem
    private weak var host: MessageTextContentView?
    private var rotorSearch: MessageTextLinkRotorSearch?

    @MainActor init(item: MessageTextAccessibilityItem, host: MessageTextContentView, parent: Any) {
      self.item = item
      self.host = host
      super.init()
      setAccessibilityParent(parent)
      setAccessibilityLabel(item.label)
      setAccessibilityValue(item.value)
      switch item.role {
      case .heading: setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
      case .text: setAccessibilityRole(.staticText)
      case .link:
        setAccessibilityRole(.link)
        setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXTextLink"))
      case .image: setAccessibilityRole(.image)
      case .codeBlock: setAccessibilityRole(.group)
      case .table: setAccessibilityRole(.scrollArea)
      }
    }

    // The element protocol, which a rotor's result needs, wants an identifier, if empty.
    override func accessibilityIdentifier() -> String {
      super.accessibilityIdentifier() ?? ""
    }

    // AppKit asks for its frame on the main thread, where the text lays out.
    override func accessibilityFrame() -> NSRect {
      let host = host
      let range = item.range
      return MainActor.assumeIsolated { host?.screenFrame(of: range) ?? .zero }
    }

    override func accessibilityPerformPress() -> Bool {
      guard case .link(let url) = item.role else { return false }
      let host = host
      return MainActor.assumeIsolated {
        guard let openURL = host?.openURL else { return false }
        openURL(url)
        return true
      }
    }

    /// Its links, which a rotor named Link steps through, as SwiftUI offers on a `Text`.
    func showLinks(_ links: [MessageTextAccessibilityElement]) {
      setAccessibilityChildren(links)
      guard !links.isEmpty else { return }
      let search = MessageTextLinkRotorSearch(links: links)
      rotorSearch = search
      setAccessibilityCustomRotors([
        NSAccessibilityCustomRotor(label: "Link", itemSearchDelegate: search)
      ])
    }
  }

  /// Finds the link before or after the rotor's current one.
  nonisolated final class MessageTextLinkRotorSearch: NSObject,
    NSAccessibilityCustomRotorItemSearchDelegate
  {
    private let links: [NSObject]

    init(links: [NSObject]) {
      self.links = links
    }

    func rotor(
      _ rotor: NSAccessibilityCustomRotor,
      resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
      let current = searchParameters.currentItem?.targetElement as? NSObject
      let index = current.flatMap { current in links.firstIndex { $0 === current } }
      let next: Int
      switch searchParameters.searchDirection {
      case .next: next = (index ?? -1) + 1
      case .previous: next = (index ?? links.count) - 1
      @unknown default: return nil
      }
      guard links.indices.contains(next),
        let target = links[next] as? any NSAccessibilityElementProtocol
      else { return nil }
      return NSAccessibilityCustomRotor.ItemResult(targetElement: target)
    }
  }

  extension MessageTextContentView {
    override func isAccessibilityElement() -> Bool { false }

    // The text's elements, as SwiftUI exposes MarkdownView's (MessageTextAccessibilityItem),
    // with each block's controls in their place. AppKit's signature makes them optional.
    // swiftlint:disable:next discouraged_optional_collection
    override func accessibilityChildren() -> [Any]? {
      if accessibilityItemsAreBuilt { return accessibilityItems }
      let items = MessageTextAccessibilityItem.items(in: document.text, chrome: document.chrome)
      accessibilityItems = items.flatMap(accessibilityElements(for:))
      accessibilityItemsAreBuilt = true
      return accessibilityItems
    }

    private func accessibilityElements(for item: MessageTextAccessibilityItem) -> [Any] {
      let element = MessageTextAccessibilityElement(item: item, host: self, parent: self)
      let children = item.children.map {
        MessageTextAccessibilityElement(item: $0, host: self, parent: element)
      }
      switch item.role {
      case .codeBlock(let block):
        let header = chromeViews[block] as? MessageCodeHeaderView
        let controls: [NSView] =
          header.map { [$0.wrapButton, $0.downloadButton, $0.copyButton] } ?? []
        for control in controls { control.setAccessibilityParent(element) }
        // A control view is ignored; its cell is what an assistive client reads.
        let read = unsafe NSAccessibility.unignoredChildren(from: controls)
        element.setAccessibilityChildren(
          Array(children.prefix(1)) + read + Array(children.dropFirst()))
        return [element]
      case .table(let block):
        element.setAccessibilityChildren(children)
        // The SwiftUI controls row's own elements follow the table, as under a SwiftUI table.
        let controls = (chromeViews[block] as? MessageTableControlsView)?.hosting
        let read = unsafe NSAccessibility.unignoredChildren(
          from: controls?.accessibilityChildren() ?? [])
        return [element] + read
      case .text:
        element.showLinks(children)
        return [element]
      case .heading, .link, .image:
        return [element]
      }
    }

    /// Where `range` of the text is on screen.
    func screenFrame(of range: NSRange) -> CGRect {
      guard let layout = textView.textLayoutManager, let content = layout.textContentManager,
        let start = content.location(content.documentRange.location, offsetBy: range.location),
        let end = content.location(start, offsetBy: range.length),
        let textRange = NSTextRange(location: start, end: end),
        let window = unsafe window
      else { return .zero }
      var union: CGRect?
      layout.enumerateTextSegments(in: textRange, type: .standard) { _, frame, _, _ in
        union = union?.union(frame) ?? frame
        return true
      }
      guard let union else { return .zero }
      return window.convertToScreen(textView.convert(union, to: nil))
    }
  }
#endif
