import Foundation
import Testing

@testable import OmnigentWorkspaceUI

// Text views count in UTF-16 offsets, as `NSString` does.
// swiftlint:disable legacy_objc_type

@Suite("Markdown formatting")
struct MarkdownFormattingTests {
  /// Applies `format` to the selection marked `«…»` in `marked` and marks the result's.
  private func apply(_ format: MarkdownFormat, _ marked: String) -> String {
    let start = (marked as NSString).range(of: "«").location
    let end = (marked as NSString).range(of: "»").location
    let text = marked.replacingOccurrences(of: "«", with: "").replacingOccurrences(
      of: "»", with: "")
    let selection = NSRange(location: start, length: end - start - 1)
    let edit = MarkdownFormatting.apply(format, to: text, selection: selection)
    let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.text) as NSString
    let after = result.replacingCharacters(
      in: NSRange(location: NSMaxRange(edit.selection), length: 0), with: "»")
    return (after as NSString).replacingCharacters(
      in: NSRange(location: edit.selection.location, length: 0), with: "«")
  }

  @Test("inline formats wrap the selection, and wrapping again unwraps it")
  func inline() {
    #expect(apply(.bold, "a «word» b") == "a **«word»** b")
    #expect(apply(.bold, "a **«word»** b") == "a «word» b")
    #expect(apply(.bold, "a «**word**» b") == "a «word» b")
    #expect(apply(.italic, "«x»") == "*«x»*")
    #expect(apply(.code, "run «ls»") == "run `«ls»`")
    #expect(apply(.strikethrough, "«»") == "~~«»~~")
  }

  @Test("a link takes the selection as its text and selects the address")
  func link() {
    #expect(apply(.link, "see «docs» now") == "see [docs](«https://») now")
    #expect(apply(.link, "x «»") == "x [«»](https://)")
  }

  @Test("block formats toggle a marker on every selected line")
  func blocks() {
    #expect(apply(.heading2, "«Title»") == "«## Title»")
    #expect(apply(.heading2, "«## Title»") == "«Title»")
    #expect(apply(.heading1, "«## Title»") == "«# Title»")
    #expect(apply(.bulletList, "«one\ntwo»") == "«- one\n- two»")
    #expect(apply(.numberedList, "«one\n\ntwo»") == "«1. one\n\n2. two»")
    #expect(apply(.taskList, "«- one»") == "«- [ ] one»")
    #expect(apply(.bulletList, "«- [ ] one»") == "«- one»")
    #expect(apply(.quote, "«> a\n> b»") == "«a\nb»")
    #expect(apply(.paragraph, "«# a\n- b»") == "«a\nb»")
  }

  @Test("a caret keeps its place in the line's text")
  func caret() {
    #expect(apply(.heading1, "x\nab«»c\ny") == "x\n# ab«»c\ny")
    #expect(apply(.heading1, "# ab«»c") == "ab«»c")
  }

  @Test("a selection ending at the next line's start leaves that line alone")
  func trailingBreak() {
    #expect(apply(.quote, "«one\n»two") == "«> one»\ntwo")
  }
}
// swiftlint:enable legacy_objc_type
