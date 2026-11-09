import Foundation
import Testing

@testable import OmnigentBrowser

/// A value whose encoding fails, as a broken encoder would.
private struct RefusesToEncode: Encodable {
  func encode(to encoder: any Encoder) throws {
    throw CocoaError(.coderInvalidValue)
  }
}

@Suite("Failures the browser's text building reports")
struct EncodingFailureTests {
  @Test("JSON that can't be encoded fails and names what it was encoding")
  func encodingRefused() {
    #expect(throws: BrowserError.self) {
      _ = try AgentBrowserScripts.jsonText(RefusesToEncode(), of: "the history to restore")
    }
    do {
      _ = try AgentBrowserScripts.jsonText(RefusesToEncode(), of: "the history to restore")
    } catch {
      #expect(error.localizedDescription.contains("the history to restore"))
    }
  }

  @Test("bytes that aren't UTF-8 fail and name what they were")
  func notText() throws {
    #expect(throws: BrowserError.self) {
      _ = try AgentBrowserScripts.utf8Text(Data([0xFF]), of: "a string")
    }
    #expect(try AgentBrowserScripts.utf8Text(Data("\"a\"".utf8), of: "a string") == "\"a\"")
  }

  @Test("a value without both quotes has no quoted text")
  func quotedValue() {
    #expect(BrowserBookmarkHTML.quotedValue(in: "HREF=") == nil)
    #expect(BrowserBookmarkHTML.quotedValue(in: "HREF=\"") == nil)
    #expect(BrowserBookmarkHTML.quotedValue(in: "HREF=\"a\"") == "a")
  }

  @MainActor
  @Test("a restore's wait times out only if it wasn't cancelled")
  func restoreWait() async {
    #expect(await BrowserTabModel.restoreWaitRanOut(sleep: {}))
    #expect(await !BrowserTabModel.restoreWaitRanOut(sleep: { throw CancellationError() }))
  }
}
