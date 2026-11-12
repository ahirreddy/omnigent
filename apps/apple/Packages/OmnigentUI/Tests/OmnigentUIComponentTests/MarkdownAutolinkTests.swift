import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("Markdown: written-out addresses and underlined links")
struct MarkdownAutolinkTests {
  private func links(_ text: AttributedString) -> [String] {
    text.runs.compactMap(\.link).map(\.absoluteString)
  }

  @Test("an address written out in prose is a link, without the punctuation after it")
  func bareAddresses() {
    let prose = "See https://example.com/a?b=1, then (http://x.test/y). Done"
    let text = MarkdownAutolink.linking(prose)
    #expect(links(text) == ["https://example.com/a?b=1", "http://x.test/y"])
    #expect(String(text.characters) == prose, "nothing is added or lost")
  }

  @Test("brackets that belong to the address stay; ones that enclose it do not")
  func brackets() {
    #expect(
      links(MarkdownAutolink.linking("https://en.wikipedia.org/wiki/Swift_(language)"))
        == ["https://en.wikipedia.org/wiki/Swift_(language)"])
    #expect(links(MarkdownAutolink.linking("[https://x.test/a]")) == ["https://x.test/a"])
    #expect(links(MarkdownAutolink.linking("**https://x.test/a**!")) == ["https://x.test/a"])
  }

  @Test("prose with no address, and an address with no host, stay plain text")
  func notLinks() {
    for prose in ["no links here", "the http protocol", "https:// and http://."] {
      let text = MarkdownAutolink.linking(prose)
      #expect(links(text).isEmpty, "\(prose)")
      #expect(String(text.characters) == prose)
    }
  }

  @Test("a parsed message links its written-out addresses, outside code, and underlines links")
  func parsed() {
    let blocks = MarkdownParser.parse(
      "Open https://a.test/x or [the site](https://b.test). Not `https://c.test` though.")
    guard case .paragraph(let text)? = blocks.first else {
      Issue.record("expected a paragraph")
      return
    }
    #expect(links(text) == ["https://a.test/x", "https://b.test"])
    for run in text.runs {
      #expect((run.underlineStyle == .single) == (run.link != nil), "\(run)")
    }
  }
}
