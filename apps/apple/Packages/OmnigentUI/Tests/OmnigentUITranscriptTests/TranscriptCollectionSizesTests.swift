#if os(iOS)
  import OmnigentViewTesting
  import SwiftUI
  import Testing
  import UIKit

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The collection transcript as what is around it changes size: the keyboard and composer
  /// below it, the window's width (rotation, split view, the iPad's sidebar) and the text size.
  @Suite("Transcript collection sizes", .serialized)
  @MainActor
  struct TranscriptCollectionSizesTests {
    @Test("The keyboard and a taller composer keep a follower at the end and a reader in place")
    func keyboardInsets() async throws {
      let conversation = collectionSession()
      let screen = try await collectionScreen(conversation)
      defer { screen.window.close() }
      #expect(screen.isAtEnd)
      let resting = screen.controller.insets.bottom
      screen.surroundings.dock = 420
      await screen.settle()
      #expect(screen.controller.insets.bottom - resting > 300)
      #expect(screen.isAtEnd, "\(screen.offset) of \(screen.controller.maximumOffset)")
      screen.surroundings.dock = 80
      await screen.settle()
      #expect(screen.isAtEnd)
      await screen.drag(to: screen.offset - 500)
      let anchor = try #require(screen.controller.readingAnchor())
      screen.surroundings.dock = 420
      await screen.settle()
      #expect(screen.isReading(anchor))
      #expect(!screen.controller.follow.follows)
    }

    @Test("Turning the window keeps the row read and measures the rows on screen at the width")
    func rotationKeepsPlace() async throws {
      let conversation = collectionSession(turns: 16)
      let screen = try await collectionScreen(conversation)
      defer { screen.window.close() }
      await screen.drag(to: screen.offset - 1400)
      let anchor = try #require(screen.controller.readingAnchor())
      let narrow = screen.controller.model.width
      let before =
        "\(screen.controller.insets) \(screen.controller.offsets.height(of: try #require(screen.controller.model.index(of: anchor.id))))"
      screen.window.window.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
      await screen.settle()
      let controller = screen.controller
      #expect(controller.model.width > narrow + 300)
      let now = try #require(controller.readingAnchor())
      #expect(now.id == anchor.id)
      let after =
        "\(controller.insets) \(controller.offsets.height(of: try #require(controller.model.index(of: anchor.id))))"
      #expect(
        abs(now.fraction - anchor.fraction) < 0.05,
        "\(now) vs \(anchor); before \(before), after \(after); \(controller.remeasured)")
      for index in controller.visibleRange {
        #expect(!controller.model.needsMeasure(at: index), "row \(index)")
      }
      screen.window.window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
      await screen.settle()
      #expect(controller.readingAnchor()?.id == anchor.id)
    }

    @Test("A larger text size measures the rows again, and the reader keeps their row")
    func dynamicType() async throws {
      let conversation = collectionSession(turns: 16)
      let screen = try await collectionScreen(conversation)
      defer { screen.window.close() }
      await screen.drag(to: screen.offset - 1400)
      let anchor = try #require(screen.controller.readingAnchor())
      let controller = screen.controller
      let row = try #require(controller.model.index(of: anchor.id))
      let before = controller.model.height(at: row)
      screen.surroundings.typeSize = .accessibility2
      await screen.settle(.milliseconds(300))
      #expect(controller.model.height(at: row) > before * 1.2)
      #expect(controller.readingAnchor()?.id == anchor.id)
      for index in controller.visibleRange {
        #expect(!controller.model.needsMeasure(at: index), "row \(index)")
      }
    }

    @Test(
      "An iPad's long transcript with its turn rail opens, follows and takes a sidebar's width",
      .timeLimit(.minutes(1)))
    func padWidths() async throws {
      let conversation = collectionSession(turns: 150)
      let screen = try await collectionScreen(
        conversation, size: CGSize(width: 820, height: 1180), layoutWidth: .regular)
      defer { screen.window.close() }
      await screen.rest()
      let controller = screen.controller
      #expect(screen.isAtEnd, "\(screen.offset) of \(controller.maximumOffset)")
      await screen.drag(to: screen.offset - 2500)
      let anchor = try #require(controller.readingAnchor())
      // The sidebar shows, then hides: the detail narrows and widens.
      screen.window.window.frame = CGRect(x: 0, y: 0, width: 500, height: 1180)
      await screen.settle()
      #expect(controller.readingAnchor()?.id == anchor.id)
      screen.window.window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
      await screen.rest()
      #expect(controller.readingAnchor()?.id == anchor.id)
      for index in controller.visibleRange {
        #expect(!controller.model.needsMeasure(at: index), "row \(index)")
      }
    }
  }
#endif
