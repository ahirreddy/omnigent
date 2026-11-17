#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// A shared session author's avatar beside their prompt in a text cell, as the SwiftUI row
  /// draws ``AuthorAvatar``.
  @Suite("Transcript table text cell avatars", .serialized)
  @MainActor
  struct TranscriptTableTextCellAvatarTests {
    init() {
      SystemSideEffects.reset()
    }

    private var shared: MessageDecoration {
      var decoration = MessageDecoration()
      decoration.showsAvatar = true
      return decoration
    }

    @Test("A shared session's prompt shows its author's initials beside it, as SwiftUI's row")
    func avatarMatchesSwiftUI() throws {
      let environment = textCellEnvironment()
      let prompt = Row(id: "u-shared", role: .user, text: "Hi from Ada", author: "Ada Lovelace")
      let cell = try shownMatchingSwiftUI(
        textCellRow(prompt, decoration: shared), environment)
      let avatar = try #require(cell.avatarView)
      #expect(!avatar.isHidden)
      #expect(avatar.initials == "AL")
      #expect(avatar.toolTip == "Ada Lovelace")
      #expect(avatar.accessibilityLabel() == "Ada Lovelace")
      #expect(cell.accessibilityLabel() == "Ada Lovelace said")
      // At the column's trailing edge and top, the bubble a small gap before it.
      let metrics = TranscriptTableTextMetrics(
        width: textCellWidth, layoutWidth: .regular, maxWidth: Theme.transcriptWidth)
      let size = TranscriptTableAvatarView.size
      #expect(
        avatar.frame
          == CGRect(
            x: metrics.columnX + metrics.columnWidth - size, y: 0, width: size, height: size))
      let bubble = try #require(cell.subviews.first { $0 is TranscriptTableBubbleView })
      #expect(abs(bubble.frame.maxX - (avatar.frame.minX - Theme.Spacing.small)) < 0.5)
      // A long prompt wraps narrower beside it, as SwiftUI's does.
      let long = Row(
        id: "u-shared-long", role: .user,
        text: String(repeating: "A long line from a shared session. ", count: 40),
        author: "Ada Lovelace")
      _ = try shownMatchingSwiftUI(textCellRow(long, decoration: shared), environment)
      // Yours shows none.
      let mine = try shownMatchingSwiftUI(
        textCellRow(TranscriptFixture.user("u-mine", "Mine")), environment)
      #expect(mine.avatarView?.isHidden != false)
      #expect(mine.accessibilityLabel() == "You said")
    }

    /// The font the avatar draws its initials in.
    private func initialsFont(_ avatar: TranscriptTableAvatarView) -> NSFont? {
      // Nothing reads the effective range back.
      unsafe avatar.drawnInitials().attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    @Test("An avatar draws the author's initials, narrowed to fit, in their color")
    func avatarDrawing() throws {
      let avatar = TranscriptTableAvatarView()
      let size = TranscriptTableAvatarView.size
      avatar.frame = CGRect(x: 0, y: 0, width: size, height: size)
      avatar.show(author: "Ada Lovelace")
      #expect(avatar.drawnInitials().string == "AL")
      let font = try #require(initialsFont(avatar))
      #expect(font.pointSize == 11)
      // Wide initials narrow, but no further than SwiftUI's minimum scale.
      avatar.show(author: "Wwwwww Mmmmmm")
      let narrowed = try #require(initialsFont(avatar))
      #expect(narrowed.pointSize >= 11 * TranscriptTableAvatarView.minimumScale)
      #expect(
        avatar.drawnInitials().size().width <= size
          || narrowed.pointSize == 11 * TranscriptTableAvatarView.minimumScale)
      // The circle is the author's color, as SwiftUI's palette picks it.
      avatar.show(author: "Ada Lovelace")
      let image = try #require(avatar.bitmapImageRepForCachingDisplay(in: avatar.bounds))
      avatar.cacheDisplay(in: avatar.bounds, to: image)
      let scale = CGFloat(image.pixelsWide) / size
      let drawn = try #require(
        image.colorAt(x: Int(3 * scale), y: Int(12 * scale))?.usingColorSpace(.sRGB))
      let hex = AuthorAvatar.color(for: "Ada Lovelace")
      #expect(abs(drawn.redComponent - CGFloat((hex >> 16) & 0xFF) / 255) < 0.03)
      #expect(abs(drawn.greenComponent - CGFloat((hex >> 8) & 0xFF) / 255) < 0.03)
      #expect(abs(drawn.blueComponent - CGFloat(hex & 0xFF) / 255) < 0.03)
    }
  }
#endif
