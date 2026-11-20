import Foundation

/// Why a workbook (or one of its sheets) can't be read.
nonisolated enum WorkbookFailure: Error, Hashable {
  /// The workbook can't be read, with the message to show.
  case unreadable(String)
  /// A part inflates past the limits; the sheet that needs it is marked too large.
  case tooLarge

  static let damaged = Self.unreadable("This Excel workbook is damaged.")
  static let tooLargeMessage = "This workbook is too large to preview. Download it to open it."

  /// The message the viewer shows when this ends the whole workbook.
  var message: String {
    switch self {
    case .unreadable(let message): message
    case .tooLarge: Self.tooLargeMessage
    }
  }
}

/// The parts of an `.xlsx` zip, inflated on demand within the workbook's allowance (web
/// `zipEntries` and `readPart`).
nonisolated struct WorkbookArchive {
  /// One part's place in the zip.
  struct Entry {
    let method: Int
    let compressedSize: Int
    let uncompressedSize: Int
    let offset: Int
  }

  /// The most bytes one part may inflate to, so a zip bomb can't exhaust memory.
  static let maxPartBytes = 64 * 1024 * 1024
  /// The most bytes all of a workbook's parts may inflate to together.
  static let maxWorkbookBytes = 256 * 1024 * 1024

  private static let endOfDirectory: UInt32 = 0x0605_4B50
  private static let directoryEntry: UInt32 = 0x0201_4B50
  private static let localHeader: UInt32 = 0x0403_4B50

  let bytes: [UInt8]
  let entries: [String: Entry]
  /// Bytes the parts may still inflate to.
  private(set) var allowance: Int

  /// The zip's directory.
  /// - Parameters:
  ///   - bytes: The file.
  ///   - allowance: The most bytes every part read may inflate to together.
  /// - Throws: ``WorkbookFailure`` when it isn't a zip or its directory is damaged.
  init(bytes: [UInt8], allowance: Int = maxWorkbookBytes) throws(WorkbookFailure) {
    self.bytes = bytes
    self.allowance = allowance
    entries = try Self.entries(bytes)
  }

  private static func entries(_ bytes: [UInt8]) throws(WorkbookFailure) -> [String: Entry] {
    // The directory's end record sits 22 bytes from the end, before an optional comment.
    let last = bytes.count - 22
    let end = stride(from: last, through: max(0, last - 0xFFFF), by: -1).first {
      uint32(bytes, $0) == endOfDirectory
    }
    guard let end else {
      throw .unreadable(
        "This file isn't a readable Excel workbook. "
          + "It may be password-protected or an older .xls file.")
    }
    var entries: [String: Entry] = [:]
    let count = uint16(bytes, end + 10) ?? 0
    var cursor = uint32(bytes, end + 16).map(Int.init) ?? -1
    for _ in 0..<count {
      guard uint32(bytes, cursor) == directoryEntry, let nameLength = uint16(bytes, cursor + 28),
        let extra = uint16(bytes, cursor + 30), let comment = uint16(bytes, cursor + 32),
        cursor + 46 + nameLength <= bytes.count
      else { throw .damaged }
      let name = SpreadsheetText.utf8(bytes[(cursor + 46)..<(cursor + 46 + nameLength)])
      entries[name] = Entry(
        method: uint16(bytes, cursor + 10) ?? 0,
        compressedSize: uint32(bytes, cursor + 20).map(Int.init) ?? 0,
        uncompressedSize: uint32(bytes, cursor + 24).map(Int.init) ?? 0,
        offset: uint32(bytes, cursor + 42).map(Int.init) ?? -1)
      cursor += 46 + nameLength + extra + comment
    }
    return entries
  }

  // The part `name` inflated, or `nil` (not an empty part) when the zip has none. Its inflated
  // (or compressed) bytes come out of the allowance, so a part can't be retried for free.
  // swiftlint:disable:next discouraged_optional_collection
  mutating func part(_ name: String) throws(WorkbookFailure) -> [UInt8]? {
    guard let entry = entries[name] else { return nil }
    guard Self.uint32(bytes, entry.offset) == Self.localHeader,
      let nameLength = Self.uint16(bytes, entry.offset + 26),
      let extraLength = Self.uint16(bytes, entry.offset + 28)
    else { throw .damaged }
    let limit = min(Self.maxPartBytes, allowance)
    if entry.uncompressedSize > limit { throw .tooLarge }
    let start = entry.offset + 30 + nameLength + extraLength
    guard start + entry.compressedSize <= bytes.count else { throw .damaged }
    let data = bytes[start..<(start + entry.compressedSize)]
    let part: [UInt8]
    switch entry.method {
    case 0:
      part = Array(data)
    case 8:
      // A spent allowance opens no more compressed parts, even one declaring no bytes.
      if limit <= 0 || data.count > limit { throw .tooLarge }
      do {
        part = try Decompression.inflate(data, limit: limit, expected: entry.uncompressedSize)
      } catch {
        allowance -= limit
        throw .tooLarge
      }
    default:
      throw .unreadable("This workbook uses a compression the preview can't read.")
    }
    if part.count > limit { throw .tooLarge }
    allowance -= max(part.count, data.count)
    return part
  }

  static func uint16(_ bytes: [UInt8], _ offset: Int) -> Int? {
    guard offset >= 0, offset + 2 <= bytes.count else { return nil }
    return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
  }

  static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= bytes.count else { return nil }
    return (0..<4).reduce(into: UInt32(0)) { value, index in
      value |= UInt32(bytes[offset + index]) << (8 * index)
    }
  }
}

/// Paths inside an Open XML package.
nonisolated enum PackagePaths {
  /// `target` resolved against the part `source` that names it, for example
  /// `("xl/workbook.xml", "../xl/worksheets/sheet1.xml")` is `xl/worksheets/sheet1.xml`; `nil`
  /// for a target that climbs out of the package (web `resolvePartPath`).
  static func resolve(_ source: String, _ target: String) -> String? {
    var segments: [Substring] =
      target.hasPrefix("/")
      ? [] : Array(source.split(separator: "/", omittingEmptySubsequences: false).dropLast())
    for segment in target.split(separator: "/", omittingEmptySubsequences: false) {
      if segment == ".." {
        guard !segments.isEmpty else { return nil }
        segments.removeLast()
      } else if segment != "." && !segment.isEmpty {
        segments.append(segment)
      }
    }
    return segments.joined(separator: "/")
  }

  /// `xl/workbook.xml` gives `xl/_rels/workbook.xml.rels`; the package (`""`) gives
  /// `_rels/.rels`.
  static func relationships(of part: String) -> String {
    let directory = part.lastIndex(of: "/").map { part[...$0] } ?? ""
    let name = part.lastIndex(of: "/").map { part[part.index(after: $0)...] } ?? Substring(part)
    return "\(directory)_rels/\(name).rels"
  }
}
