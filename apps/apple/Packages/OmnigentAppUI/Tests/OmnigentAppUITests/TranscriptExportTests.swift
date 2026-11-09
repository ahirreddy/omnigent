import Foundation
import OmnigentStores
import Testing
import UniformTypeIdentifiers

@testable import OmnigentAppUI

/// The transcript file the save panel writes.
@Suite("Transcript export")
struct TranscriptExportTests {
  @Test("Its bytes are the text, and read back to it, unicode included")
  func roundTrip() throws {
    let text = "{\"text\":\"h\u{00E9}llo \u{1F600}\"}\n"
    let export = TranscriptExport(text: text)
    #expect(export.fileContents == Data(text.utf8))
    #expect(try TranscriptExport(fileContents: export.fileContents).text == text)
    #expect(try TranscriptExport(fileContents: Data()).text.isEmpty)
  }

  @Test("A file that's missing or isn't text is refused")
  func corruptFiles() {
    #expect(throws: CocoaError.self) { try TranscriptExport(fileContents: nil) }
    #expect(throws: CocoaError.self) { try TranscriptExport(fileContents: Data([0xFF, 0xFE])) }
  }

  @Test("The file is .jsonl where the system knows that, else JSON")
  func contentTypes() {
    #expect(TranscriptExport.contentType.preferredFilenameExtension == "jsonl")
    #expect(TranscriptExport.readableContentTypes == [TranscriptExport.contentType])
    #expect(TranscriptExport.contentType(forExtension: "") == .json)
  }
}
