#if os(iOS)
  import OmnigentViewTesting
  import SwiftUI
  import Testing
  import UIKit

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// A text row's input on iPhone and iPad: selection and its edit menu, the context menu off
  /// the text, links, VoiceOver and a code block's controls.
  @Suite("Transcript collection text row input", .serialized)
  @MainActor
  struct TranscriptCollectionTextInputTests {
    @Test("A long press selects the text; the edit menu adds Reply, Ask in side chat and Message")
    func selectionMenu() throws {
      var replied: [String] = []
      let style = textRowStyle { values in
        var actions = ConversationActions()
        actions.replyWithSelection = { replied.append($0) }
        actions.askInSideChat = { _ in }
        values.conversationActions = actions
      }
      let (view, window) = try shownTextRow(
        TranscriptFixture.answer("a-select", "- first item\n- second item"), style: style)
      defer { window.close() }
      let run = try #require(view.runView)
      run.beginSelecting(at: CGPoint(x: 40, y: run.raster.topInset + 10))
      let live = try #require(run.live)
      let whole = NSRange(location: 0, length: live.attributedText.length)
      let menu = try #require(
        run.textView(live, editMenuForTextIn: whole, suggestedActions: []))
      let offered = menuTitles(menu.children)
      #expect(offered.starts(with: ["Reply", "Ask in Side Chat", "Message"]), "\(offered)")
      #expect(offered.contains("Fork from Here\u{2026}") == false)
      #expect(offered.contains("Copy Message ID"))
      // A copy gives the text as the message reads: no list markers, no clear glyphs.
      live.selectedRange = whole
      let copied = live.copiedText
      #expect(copied.contains("first item") && copied.contains("second item"), "\(copied)")
      #expect(!copied.contains("\u{2022}"), "\(copied)")
      #expect(replied.isEmpty)
      run.endSelecting()
      #expect(run.live == nil)
    }

    @Test("A long press off the text opens the message's menu; on the text it selects instead")
    func contextMenu() throws {
      let style = textRowStyle { values in
        var actions = ConversationActions()
        actions.replyWithSelection = { _ in }
        actions.forkFrom = { _ in }
        values.conversationActions = actions
      }
      let (view, window) = try shownTextRow(
        TranscriptFixture.user("u-menu", "A prompt"), style: style)
      defer { window.close() }
      let interaction = try #require(
        view.interactions.compactMap { $0 as? UIContextMenuInteraction }.first)
      let frames = try #require(view.frames)
      let onText = CGPoint(x: frames.run.minX + 4, y: frames.run.midY)
      let onBubble = CGPoint(x: frames.run.minX - 8, y: frames.run.midY)
      #expect(view.isOnText(onText))
      #expect(
        view.contextMenuInteraction(interaction, configurationForMenuAtLocation: onText) == nil)
      #expect(
        view.contextMenuInteraction(interaction, configurationForMenuAtLocation: onBubble) != nil)
      let offered = menuTitles(view.messageMenu())
      #expect(offered.starts(with: ["Reply"]), "\(offered)")
      #expect(offered.contains("Copy"))
      #expect(offered.contains("Share"))
      #expect(offered.last == "Copy Message ID")
    }

    @Test("Links open from a tap; VoiceOver reads headings, paragraphs and links with the actions")
    func linksAndVoiceOver() throws {
      var opened: [URL] = []
      let style = textRowStyle { values in
        values.openURL = OpenURLAction { url in
          opened.append(url)
          return .handled
        }
        var actions = ConversationActions()
        actions.replyWithSelection = { _ in }
        values.conversationActions = actions
      }
      let (view, window) = try shownTextRow(
        TranscriptFixture.answer("a-links", "## Title\n\nRead [the docs](https://example.com/a)."),
        style: style)
      defer { window.close() }
      let run = try #require(view.runView)
      let area = try #require(run.raster.links.first)
      run.tap(at: CGPoint(x: area.rect.midX, y: area.rect.midY + run.raster.topInset))
      #expect(opened.map(\.absoluteString) == ["https://example.com/a"])
      let elements = (run.accessibilityElements ?? []).compactMap { $0 as? MessageTextRunElement }
      let heading = try #require(elements.first)
      #expect(heading.accessibilityLabel == "Title")
      #expect(heading.accessibilityTraits.contains(.header))
      #expect(heading.accessibilityFrameInContainerSpace.height > 0)
      let link = try #require(elements.first { $0.accessibilityTraits.contains(.link) })
      #expect(link.accessibilityLabel == "the docs")
      #expect(link.accessibilityActivate())
      #expect(opened.count == 2)
      let actions = heading.accessibilityCustomActions?.map(\.name) ?? []
      #expect(actions.contains("Copy"))
      #expect(actions.contains("Reply"))
    }

    @Test("A code block's Copy and Download sit over its drawn header, for its code")
    func codeControls() throws {
      let style = textRowStyle()
      let (view, window) = try shownTextRow(
        TranscriptFixture.answer("a-code", "Run:\n\n```swift\nlet x = 1\n```"), style: style)
      defer { window.close() }
      let run = try #require(view.runView)
      let controls = try #require(run.chromeViews.values.first as? MessageTextCodeControls)
      let header = try #require(run.raster.chromeFrames.values.first)
      #expect(controls.frame.minY == header.minY + run.raster.topInset)
      #expect(controls.code == "let x = 1")
      #expect(controls.copyButton.accessibilityLabel == "Copy code")
      // A package test has no application to send a control's actions; the button's runs.
      controls.copyCode()
      #expect(controls.copyButton.accessibilityLabel == "Copied")
      let elements = run.accessibilityElements ?? []
      #expect(elements.contains { ($0 as? UIView) === controls })
    }
  }
#endif
