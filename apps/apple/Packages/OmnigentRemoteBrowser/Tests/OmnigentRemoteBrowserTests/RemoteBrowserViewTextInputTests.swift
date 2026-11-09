#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentCoreFFI
  import Testing

  @testable import OmnigentRemoteBrowser

  @MainActor
  @Suite("Remote browser view, text input client", .serialized)
  struct RemoteBrowserViewTextInputTests {
    private let oddRanges = [
      NSRange(location: NSNotFound, length: 0), NSRange(location: 0, length: 0),
      NSRange(location: -1, length: -1), NSRange(location: .max, length: .max),
      NSRange(location: .min, length: .min), NSRange(location: 5, length: .max),
    ]

    @Test("committed text reaches the page, whatever it was given")
    func committing() async {
      let (hosted, view) = await inControl()
      defer { hosted.finish() }
      view.insertText("a", replacementRange: oddRanges[0])
      view.insertText(NSAttributedString(string: "b"), replacementRange: oddRanges[0])
      view.insertText(42, replacementRange: oddRanges[0])
      let sent = hosted.connector.driver.ime
      #expect(sent.map(\.text) == ["a", "b", ""])
      #expect(sent.allSatisfy { $0.op == .commit && $0.replacement == nil })
    }

    @Test("composition marks, updates, and ends")
    func composing() async {
      let (hosted, view) = await inControl()
      defer { hosted.finish() }
      let none = oddRanges[0]
      #expect(!view.hasMarkedText())
      view.setMarkedText(
        "か", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
      #expect(view.hasMarkedText())
      #expect(view.markedRange() == NSRange(location: 0, length: 1))
      view.unmarkText()
      #expect(!view.hasMarkedText())
      view.setMarkedText("", selectedRange: none, replacementRange: none)
      view.finishComposing(keepSelection: true)
      view.cancelComposition()
      #expect(
        hosted.connector.driver.ime.map(\.op) == [
          .setComposition, .finish, .cancel, .finish, .cancel,
        ])
    }

    @Test("ranges of any shape send a range or none")
    func oddRangesOfText() async {
      let (hosted, view) = await inControl()
      defer { hosted.finish() }
      for range in oddRanges {
        view.commitText("x", replacementRange: range)
        view.setComposition("x", selectedRange: range, replacementRange: range)
      }
      #expect(hosted.connector.driver.ime.count == oddRanges.count * 2)
    }

    @Test("a remote page mirrors no text")
    func nothingMirrored() async {
      let (hosted, view) = await inControl()
      defer { hosted.finish() }
      #expect(view.selectedRange().location == NSNotFound)
      #expect(view.characterIndex(for: NSPoint(x: CGFloat.nan, y: 0)) == NSNotFound)
      let substring = unsafe view.attributedSubstring(
        forProposedRange: oddRanges[3], actualRange: nil)
      #expect(substring == nil)
      #expect(!view.validAttributesForMarkedText().isEmpty)
      view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
      #expect(hosted.connector.driver.keys.isEmpty)
    }

    @Test("the candidate window goes under the page, or nowhere with no window")
    func candidateWindow() async {
      let (hosted, view) = await inControl()
      defer { hosted.finish() }
      let windowless = unsafe view.firstRect(forCharacterRange: oddRanges[3], actualRange: nil)
      #expect(windowless == .zero)
      let window = neverShownWindow(size: CGSize(width: 1000, height: 1000))
      window.contentView = view
      defer { window.contentView = nil }
      let rect = unsafe view.firstRect(forCharacterRange: oddRanges[3], actualRange: nil)
      #expect(rect.minX.isFinite)
      #expect(rect.minX < -10_000)
      #expect(view.hostWindowScale > 0)
    }
  }
#endif
