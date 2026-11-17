#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// What an assistive client reads in a TextKit message, beside the SwiftUI renderer's.
  @MainActor
  @Suite("A TextKit message's accessibility beside SwiftUI's", .serialized)
  struct MessageTextAccessibilityTests {
    private static let markdown = """
      # Title

      Body with [a link](https://example.com/a) and [another](https://example.com/b) here.

      - item one
      - [x] done task

      1. first

      ```swift
      let a = 1
      ```

      > quoted

      ---

      | A | B |
      | - | - |
      | 1 | 2 |
      """

    private func screen(_ renderer: MessageTextRenderer) -> OffscreenWindow<AnyView> {
      OffscreenWindow(
        AnyView(
          MessageMarkdown(text: Self.markdown)
            .environment(\.messageTextRenderer, renderer)
            .frame(width: 600, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)),
        width: 600, height: 800)
    }

    private static func attribute(_ name: String, of element: NSObject) -> Any? {
      element.responds(to: NSSelectorFromString(name)) ? element.value(forKey: name) : nil
    }

    /// Each element under `root`, as `depth role subrole label value rotors`, in reading order.
    private static func elements(under root: NSObject, depth: Int = 0) -> [String] {
      var found: [String] = []
      for child in attribute("accessibilityChildren", of: root) as? [Any] ?? [] {
        guard let element = child as? NSObject else { continue }
        let rotors =
          (attribute("accessibilityCustomRotors", of: element)
          as? [NSAccessibilityCustomRotor])?.map(\.label) ?? []
        let fields = [
          "\(depth)", attribute("accessibilityRole", of: element) as? String ?? "",
          attribute("accessibilitySubrole", of: element) as? String ?? "",
          attribute("accessibilityLabel", of: element) as? String ?? "",
          attribute("accessibilityValue", of: element).map { "\($0)" } ?? "", "\(rotors)",
        ]
        found.append(fields.joined(separator: "|"))
        found += elements(under: element, depth: depth + 1)
      }
      return found
    }

    private func read(_ renderer: MessageTextRenderer) throws -> [String] {
      let screen = screen(renderer)
      defer { screen.close() }
      return try screen.withAccessibilityTree {
        _ = Self.elements(under: screen.host)
        screen.settle(0.2)
        return Self.elements(under: screen.host)
      }
    }

    @Test("Headings, paragraphs and links, list numbers and task boxes, code and tables read alike")
    func sameElements() throws {
      let swiftUI = try read(.swiftUI)
      let textKit = try read(.textKit)
      #expect(textKit == swiftUI, "\(textKit)\nvs\n\(swiftUI)")
      #expect(swiftUI.contains { $0.hasPrefix("0|AXHeading||Title|Title") })
    }

    @Test("A link opens its address when pressed; the Link rotor steps through a paragraph's links")
    func links() throws {
      let opened = HostLog()
      let screen = transcriptScreen(
        MessageMarkdown(text: Self.markdown)
          .environment(\.messageTextRenderer, .textKit)
          .environment(
            \.openURL,
            OpenURLAction { url in
              opened.add(url.absoluteString)
              return .handled
            }), width: 600, height: 800)
      defer { screen.close() }
      let content = try #require(MessageTextFixture.contentViews(in: screen).first)
      let elements = try #require(content.accessibilityChildren() as? [NSObject])
      let body = try #require(
        elements.compactMap { $0 as? MessageTextAccessibilityElement }.first {
          $0.item.value?.hasPrefix("Body") == true
        })
      let links = try #require(body.accessibilityChildren() as? [MessageTextAccessibilityElement])
      #expect(links.map { $0.accessibilityLabel() } == ["a link", "another"])
      #expect(links[0].accessibilityFrame().width > 0, "it is where its words are")
      #expect(links[1].accessibilityPerformPress())
      #expect(opened.entries == ["https://example.com/b"])
      let rotor = try #require(body.accessibilityCustomRotors().first)
      #expect(rotor.label == "Link")
      let search = try #require(rotor.itemSearchDelegate)
      let first = NSAccessibilityCustomRotor.SearchParameters()
      first.searchDirection = .next
      let found = search.rotor(rotor, resultFor: first)?.targetElement as? NSObject
      #expect(found === links[0])
      let next = NSAccessibilityCustomRotor.SearchParameters()
      next.searchDirection = .next
      next.currentItem = NSAccessibilityCustomRotor.ItemResult(targetElement: links[0])
      #expect(search.rotor(rotor, resultFor: next)?.targetElement as? NSObject === links[1])
    }
  }
#endif
