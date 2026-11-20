import Foundation
import Testing

@testable import OmnigentWorkspaceUI

/// Parquet files read for the table preview, against the web's `parquet.test.ts` fixtures.
@Suite("Parquet preview")
struct SpreadsheetParquetTests {
  private typealias Fixtures = SpreadsheetFixtures

  private static func table(_ name: String, maxValues: Int = ParquetReader.maxValues) throws
    -> DataTablePreview?
  {
    try ParquetReader.read(try Fixtures.bytes(name), maxValues: maxValues).flatMap(Fixtures.table)
  }

  private static func message(_ name: String) throws -> String? {
    let read = SpreadsheetReader.read(
      Data(try Fixtures.bytes(name)), format: .parquet, truncated: false
    ) { Fixtures.table($0) }
    if case .unreadable(let message) = read { return message }
    return nil
  }

  @Test("the schema and rows read, each type as text")
  func sales() throws {
    let table = try #require(try Self.table("sales.snappy.parquet"))
    #expect(
      table.columns.map(\.name) == [
        "region", "units", "revenue", "closed", "seen_at", "won", "tags",
      ])
    #expect(
      table.rows == [
        ["West", "10", "1234.5", "2026-03-01", "2026-03-01T12:00:00Z", "true", "[\"a\",\"b\"]"],
        ["East", "2", "99.95", "2026-01-15", "", "false", "[]"],
        ["North", "", "0.5", "", "2026-02-01T08:05:00Z", "true", ""],
      ])
    #expect(table.summary == "3 rows \u{00B7} 7 columns \u{00B7} Parquet")
  }

  @Test("binary columns show their size while annotated strings decode")
  func binary() throws {
    let table = try #require(try Self.table("binary.parquet"))
    #expect(table.columns.map(\.name) == ["blob", "name"])
    #expect(table.rows == [["(3 bytes)", "café"]])
  }

  @Test("the first rows are kept and all of them counted from the footer")
  func rows() throws {
    let table = try #require(try Self.table("rows2500.parquet"))
    #expect(table.rows.count == 1000)
    #expect(table.rows.last == ["999", "row 999"])
    #expect(table.totalRows == 2500)
  }

  @Test("the first 500 columns of a wider file show, every column counted")
  func wide() throws {
    let table = try #require(try Self.table("wide520.parquet"))
    #expect(table.columns.count == 500)
    #expect(table.columns.last?.name == "c499")
    #expect(table.totalColumns == 520)
    #expect(table.rows.first?.last == "499")
  }

  @Test("nested text is built only as far as the table can keep it")
  func repeatedList() throws {
    let table = try #require(try Self.table("repeated-list.parquet"))
    #expect(table.rows.count == 1, "the row past the budget is the last one built")
    let cell = try #require(table.rows.first?.first)
    #expect(cell.hasSuffix("\u{2026}"))
    #expect(cell.utf16.count <= DataTablePreview.maxChars + 1)
    #expect(table.totalRows == 1000)
  }

  @Test("whole flat chunks count against the value limit before any is read")
  func valueLimit() throws {
    #expect(throws: SpreadsheetFailure.self) {
      try ParquetReader.read(try Fixtures.bytes("flat-one-group.parquet"), maxValues: 50_000)
    }
  }

  @Test("nested columns past the value limit show a placeholder while flat columns fill in")
  func skippedNested() throws {
    let listOnly = try #require(try Self.table("repeated-list.parquet", maxValues: 1_000_000))
    #expect(listOnly.rows.count == 1000)
    #expect(Set(listOnly.rows.map { $0.joined() }) == [ParquetText.skippedNested])
    let mixed = try #require(try Self.table("list-and-id.parquet", maxValues: 1_000_000))
    #expect(mixed.columns.map(\.name) == ["id", "l"])
    #expect(mixed.rows.count == 1000)
    #expect(
      Array(mixed.rows.prefix(3)) == [
        ["0", ParquetText.skippedNested], ["1", ParquetText.skippedNested],
        ["2", ParquetText.skippedNested],
      ])
  }

  @Test("a codec the preview can't read is named, and a file that isn't Parquet says so")
  func unreadable() throws {
    #expect(
      try Self.message("sales.zstd.parquet")
        == "This file is compressed with ZSTD, which the preview can't read yet. "
        + "Download it to open it.")
    let other = SpreadsheetReader.read(
      Data("not parquet at all".utf8), format: .parquet, truncated: false
    ) { Fixtures.table($0) }
    #expect(other == .unreadable("This file isn't a readable Parquet file."))
  }

  @Test("values show as the web shows them")
  func cellText() {
    let march = SpreadsheetText.days(year: 2026, month: 3, day: 1) * SpreadsheetText.dayMillis
    #expect(ParquetText.cell(.date(millis: nil), isDate: false) == "(out-of-range date)")
    #expect(ParquetText.cell(.date(march), isDate: true) == "2026-03-01")
    #expect(ParquetText.cell(.date(march + 45_000_000), isDate: false) == "2026-03-01T12:30:00Z")
    #expect(ParquetText.cell(.bigInt(12), isDate: false) == "12")
    let object = ParquetValue.object([ParquetField(name: "a", value: .bigInt(1))])
    #expect(ParquetText.cell(object, isDate: false) == "{\"a\":\"1\"}")
    let nested = ParquetValue.object([
      ParquetField(name: "a", value: .list([.number(1), .null, .text("x")])),
      ParquetField(name: "b", value: .object([ParquetField(name: "c", value: .bool(true))])),
      ParquetField(name: "skipped", value: .missing),
    ])
    #expect(ParquetText.cell(nested, isDate: false) == "{\"a\":[1,null,\"x\"],\"b\":{\"c\":true}}")
    let list = ParquetValue.list([.date(march), .bytes(3)])
    #expect(ParquetText.cell(list, isDate: false) == "[\"2026-03-01T00:00:00.000Z\",\"(3 bytes)\"]")
    let long = ParquetValue.list([.text("abc"), .text("abc"), .text("abc")])
    #expect(ParquetText.cell(long, isDate: false, limit: 8) == "[\"abc\",\"\u{2026}")
  }
}
