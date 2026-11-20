import Compression
import Foundation
import Testing

@testable import OmnigentWorkspaceUI

/// Excel's serials and number formats, JavaScript's number text, and the decoders the
/// spreadsheet readers use, as the web's `xlsx.test.ts` and `parquet.test.ts` check them.
@Suite("Spreadsheet values and decoders")
struct SpreadsheetValueTests {
  @Test(
    "an Excel serial shows as a date, a time or both",
    arguments: [
      (45_658.0, false, "2025-01-01"), (45_658.5, false, "2025-01-01 12:00:00"),
      (0.25, false, "06:00:00"), (1, false, "1900-01-01"), (59, false, "1900-02-28"),
      (60, false, "1900-02-29"), (60.5, false, "1900-02-29 12:00:00"), (61, false, "1900-03-01"),
      (0, true, "1904-01-01"), (1e12, false, "1000000000000"), (-1, false, "-1"),
      (2_958_465, false, "9999-12-31"), (2_958_465, true, "2958465"),
      (0.4166666, false, "10:00:00"), (0.5, true, "1904-01-01 12:00:00"),
      (59.999999, false, "1900-02-29 00:00:00"), (60.999999, false, "1900-03-01 00:00:00"),
      (2_958_465.99998, false, "9999-12-31 23:59:58"),
      (2_958_465.99999999, false, "2958465.99999999"),
    ])
  func serials(serial: Double, date1904: Bool, text: String) {
    #expect(ExcelValues.serialText(serial, date1904: date1904) == text)
  }

  @Test("time, date and elapsed formats are told apart")
  func formats() {
    let time = [
      "hh:mm", "h:mm AM/PM", "[h]:mm:ss", "mm:ss", "e h:mm", "yyyy-mm-dd hh:mm", "mmm-yy",
    ]
    #expect(time.map(ExcelValues.isTimeFormat) == [true, true, false, true, false, false, false])
    let dates = ["yyyy-mm-dd", "[$-409]mmm d, yyyy", "[h]:mm", "0.00%", "\"m\"0", "[Red]#,##0"]
    #expect(dates.map(ExcelValues.isDateFormat) == [true, true, true, false, false, false])
    #expect(!ExcelValues.isDateFormat("General"))
    let elapsed = ["[h]:mm:ss", "[h]:mm", "[mm]:ss", "[ss]", "h:mm", "\"[h]\" mm"].map(
      ExcelValues.elapsedFormat)
    #expect(
      elapsed == [
        ExcelElapsedFormat(unit: .hours, showsSeconds: true),
        ExcelElapsedFormat(unit: .hours, showsSeconds: false),
        ExcelElapsedFormat(unit: .minutes, showsSeconds: true),
        ExcelElapsedFormat(unit: .seconds, showsSeconds: true), nil, nil,
      ])
  }

  @Test("elapsed time counts in its largest unit")
  func elapsedText() {
    let hours = ExcelElapsedFormat(unit: .hours, showsSeconds: true)
    #expect(ExcelValues.elapsedText(1.5, format: hours) == "36:00:00")
    #expect(
      ExcelValues.elapsedText(1.5, format: ExcelElapsedFormat(unit: .hours, showsSeconds: false))
        == "36:00")
    #expect(
      ExcelValues.elapsedText(1.5, format: ExcelElapsedFormat(unit: .minutes, showsSeconds: true))
        == "2160:00")
    #expect(
      ExcelValues.elapsedText(1.5, format: ExcelElapsedFormat(unit: .seconds, showsSeconds: true))
        == "129600")
    #expect(ExcelValues.elapsedText(0.000_694_444_4, format: hours) == "0:01:00")
    #expect(ExcelValues.elapsedText(-0.5, format: hours) == "-12:00:00")
  }

  @Test("numbers read as JavaScript writes them, and Excel's at 15 digits")
  func numbers() {
    let cases: [(Double, String)] = [
      (1, "1"), (-0.0, "0"), (1234.5, "1234.5"), (0.1, "0.1"), (1e21, "1e+21"),
      (1.2345678901234568e20, "123456789012345680000"), (1e-7, "1e-7"),
      (0.000_001, "0.000001"), (-2.5e-8, "-2.5e-8"),
    ]
    for (value, text) in cases { #expect(SpreadsheetText.number(value) == text) }
    #expect(SpreadsheetText.excelNumber("0.30000000000000004") == "0.3")
    #expect(SpreadsheetText.excelNumber("12abc") == "12abc")
  }

  @Test("relationship targets resolve against the part that names them")
  func paths() {
    #expect(
      PackagePaths.resolve("xl/workbook.xml", "worksheets/sheet1.xml") == "xl/worksheets/sheet1.xml"
    )
    #expect(
      PackagePaths.resolve("xl/workbook.xml", "../xl/worksheets/./sheet1.xml")
        == "xl/worksheets/sheet1.xml")
    #expect(PackagePaths.resolve("xl/workbook.xml", "/xl/styles.xml") == "xl/styles.xml")
    #expect(PackagePaths.resolve("", "xl/workbook.xml") == "xl/workbook.xml")
    #expect(PackagePaths.resolve("xl/workbook.xml", "../../outside.xml") == nil)
    #expect(PackagePaths.relationships(of: "xl/workbook.xml") == "xl/_rels/workbook.xml.rels")
    #expect(PackagePaths.relationships(of: "") == "_rels/.rels")
  }

  @Test("raw deflate and gzip inflate within their limit")
  func inflate() throws {
    let text = Array(String(repeating: "spreadsheet ", count: 200).utf8)
    let deflated = Self.deflate(text)
    try #require(!deflated.isEmpty)
    #expect(try Decompression.inflate(deflated[...], limit: text.count) == text)
    #expect(throws: DecompressionFailure.tooLarge) {
      try Decompression.inflate(deflated[...], limit: text.count - 1)
    }
    // A gzip member: its header, the deflate stream, then a trailer the inflater ignores.
    let member: [UInt8] =
      [0x1F, 0x8B, 8, 0x08, 0, 0, 0, 0, 0, 3] + Array("a.bin".utf8) + [0]
      + deflated + Array(repeating: 0, count: 8)
    #expect(try Decompression.gunzip(member[...], limit: text.count) == text)
    #expect(throws: DecompressionFailure.malformed) {
      try Decompression.gunzip([1, 2, 3][...], limit: 10)
    }
  }

  @Test("a Snappy block's literals and copies, overlapping ones included")
  func snappy() throws {
    // "abcd" as a literal, then a copy of 8 from 4 back: "abcdabcdabcd".
    let block: [UInt8] = [12, 3 << 2, 0x61, 0x62, 0x63, 0x64, 0b0001_0001, 4]
    #expect(try Snappy.decompress(block[...], limit: 12) == Array("abcdabcdabcd".utf8))
    #expect(throws: Snappy.Malformed.self) { try Snappy.decompress(block[...], limit: 11) }
  }

  @Test("the RLE hybrid and delta encodings decode")
  func encodings() throws {
    // An RLE run of five 3s, then one bit-packed group of 0...7 at three bits.
    let hybrid: [UInt8] = [5 << 1, 3, 1 << 1 | 1, 0x88, 0xC6, 0xFA]
    #expect(
      try ParquetEncodings.hybrid(hybrid[...], bitWidth: 3, count: 13) == [
        3, 3, 3, 3, 3, 0, 1, 2, 3, 4, 5, 6, 7,
      ])
    // DELTA_BINARY_PACKED: block 128, 4 miniblocks, 5 values from 7, each 2 more than the last.
    let delta: [UInt8] = [128, 1, 4, 5, 14, 4, 0, 0, 0, 0]
    var cursor = ParquetCursor(delta[...])
    #expect(try ParquetEncodings.deltaBinaryPacked(&cursor) == [7, 9, 11, 13, 15])
  }

  private static func deflate(_ input: [UInt8]) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: input.count + 64)
    let written = output.withUnsafeMutableBufferPointer { destination in
      input.withUnsafeBufferPointer { source in
        guard let target = destination.baseAddress, let origin = source.baseAddress else {
          return 0
        }
        return unsafe compression_encode_buffer(
          target, destination.count, origin, source.count, nil, COMPRESSION_ZLIB)
      }
    }
    return Array(output.prefix(written))
  }
}
