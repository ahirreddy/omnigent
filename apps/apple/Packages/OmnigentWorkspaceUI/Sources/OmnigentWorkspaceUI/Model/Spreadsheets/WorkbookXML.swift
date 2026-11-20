import Foundation

/// Reads a workbook part's XML by local name, whatever namespace prefix it carries: the Open XML
/// SDK writes `<x:row>` where Excel writes `<row>`.
nonisolated class WorkbookXMLReader: NSObject, XMLParserDelegate {
  /// Parses `part`, calling the subclass's element and text methods.
  /// - Parameter part: The part's bytes.
  /// - Throws: ``WorkbookFailure/damaged`` for malformed XML.
  final func parse(_ part: [UInt8]) throws(WorkbookFailure) {
    let parser = XMLParser(data: Data(Self.utf8Declared(part)))
    // The parser holds its delegate unretained; this reader outlives the parse.
    unsafe parser.delegate = self
    guard parser.parse() else { throw .damaged }
  }

  /// Called at each element's start, with its local name.
  func start(_ name: String, attributes: [String: String]) {}
  /// Called at each element's end, with its local name.
  func end(_ name: String) {}
  /// Called with text inside the current element, possibly in pieces.
  func text(_ text: String) {}

  final func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String] = [:]
  ) {
    start(Self.localName(elementName), attributes: attributes)
  }

  final func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName: String?
  ) {
    end(Self.localName(elementName))
  }

  final func parser(_ parser: XMLParser, foundCharacters string: String) {
    text(string)
  }

  final func parser(_ parser: XMLParser, foundCDATA block: Data) {
    text(SpreadsheetText.utf8(block))
  }

  /// `x:row` is `row`.
  static func localName(_ name: String) -> String {
    name.lastIndex(of: ":").map { String(name[name.index(after: $0)...]) } ?? name
  }

  /// A prefixed attribute's value by its local name, for example `r:id`.
  static func prefixed(_ local: String, in attributes: [String: String]) -> String? {
    attributes.first { key, _ in key.contains(":") && localName(key) == local }?.value
  }

  /// ASCII-shaped bytes whose declaration names UTF-16 (or UCS-2) are UTF-8: the declaration
  /// is dropped so the parser reads them as such.
  private static func utf8Declared(_ part: [UInt8]) -> [UInt8] {
    guard part.starts(with: Array("<?xml".utf8)), let close = part.prefix(256).firstIndex(of: 0x3E)
    else { return part }
    let declaration = SpreadsheetText.utf8(part[...close]).lowercased()
    guard declaration.contains("utf-16") || declaration.contains("ucs-2") else { return part }
    return Array(part[(close + 1)...])
  }
}

/// A part's relationships (`_rels/*.rels`).
nonisolated final class RelationshipsXML: WorkbookXMLReader {
  struct Relationship {
    let id: String
    let type: String
    let target: String
    let external: Bool
  }

  private(set) var relationships: [Relationship] = []

  override func start(_ name: String, attributes: [String: String]) {
    guard name == "Relationship" else { return }
    relationships.append(
      Relationship(
        id: attributes["Id"] ?? "", type: attributes["Type"] ?? "",
        target: attributes["Target"] ?? "", external: attributes["TargetMode"] == "External"))
  }
}

/// The workbook part: its sheets, in order, and its date system.
nonisolated final class WorkbookPartXML: WorkbookXMLReader {
  struct Sheet {
    let name: String?
    let hidden: Bool
    let relationshipID: String?
  }

  private(set) var sheets: [Sheet] = []
  private(set) var date1904 = false

  override func start(_ name: String, attributes: [String: String]) {
    switch name {
    case "workbookPr":
      date1904 = ["1", "true"].contains(attributes["date1904"] ?? "")
    case "sheet":
      sheets.append(
        Sheet(
          name: attributes["name"],
          hidden: ["hidden", "veryHidden"].contains(attributes["state"] ?? ""),
          relationshipID: Self.prefixed("id", in: attributes)))
    default:
      break
    }
  }
}

/// Text runs (`<t>`) under an element, leaving out phonetic guides (`<rPh>`).
nonisolated struct RunText {
  private var inRun = false
  private var phoneticDepth = 0
  private(set) var text = ""

  mutating func start(_ name: String) {
    if name == "rPh" { phoneticDepth += 1 }
    if name == "t", phoneticDepth == 0 { inRun = true }
  }

  mutating func end(_ name: String) {
    if name == "rPh" { phoneticDepth -= 1 }
    if name == "t" { inRun = false }
  }

  mutating func append(_ string: String) {
    if inRun { text += string }
  }
}

/// The shared strings part: each `<si>`'s text.
nonisolated final class SharedStringsXML: WorkbookXMLReader {
  private(set) var strings: [String] = []
  private var current: RunText?

  override func start(_ name: String, attributes: [String: String]) {
    if name == "si" { current = RunText() } else { current?.start(name) }
  }

  override func end(_ name: String) {
    if name == "si", let current {
      strings.append(current.text)
      self.current = nil
    } else {
      current?.end(name)
    }
  }

  override func text(_ text: String) {
    current?.append(text)
  }
}

/// The styles part: custom number formats, and each cell format's number format.
nonisolated final class StylesXML: WorkbookXMLReader {
  private(set) var customFormats: [Int: String] = [:]
  /// Each cell format's (`<cellXfs>`'s `<xf>`) number format id, in order.
  private(set) var cellFormats: [Int] = []
  private var cellFormatsDepth = 0
  private var sawCellFormats = false

  override func start(_ name: String, attributes: [String: String]) {
    switch name {
    case "numFmt":
      if let id = attributes["numFmtId"].flatMap(Int.init) {
        customFormats[id] = attributes["formatCode"] ?? ""
      }
    case "cellXfs":
      // Only the first list counts, as the web reads it.
      if !sawCellFormats { cellFormatsDepth += 1 }
      sawCellFormats = true
    case "xf" where cellFormatsDepth > 0:
      cellFormats.append(attributes["numFmtId"].flatMap(Int.init) ?? 0)
    default:
      break
    }
  }

  override func end(_ name: String) {
    if name == "cellXfs", cellFormatsDepth > 0 { cellFormatsDepth -= 1 }
  }
}
