#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// A preference with a dot in its key renders its reader for its own changes only.
  @MainActor
  @Suite("Stored preferences", .serialized)
  struct StoredPreferenceTests {
    private static let key = "probe.stored.choice"

    /// Body evaluations of the views under test.
    fileprivate final class Renders {
      var count = 0
    }

    fileprivate enum Choice: String {
      case first, second
    }

    /// What the test has the view choose.
    @Observable
    fileprivate final class Chosen {
      var value: Choice?
    }

    /// Reads the preference through the modifier, and sets it from `chosen`.
    fileprivate struct Reader: View {
      let renders: Renders
      let chosen: Chosen
      @State private var choice = Choice.first

      var body: some View {
        renders.count += 1
        return Text("reader \(choice.rawValue)")
          .onChange(of: chosen.value) { if let value = chosen.value { choice = value } }
          .modifier(
            StoredPreference(
              $choice, stored: AppStorage(wrappedValue: .first, StoredPreferenceTests.key)))
      }
    }

    /// Reads the preference the way that renders for every write.
    private struct DirectReader: View {
      let renders: Renders
      @AppStorage(StoredPreferenceTests.key) private var choice = Choice.first

      var body: some View {
        renders.count += 1
        return Text("direct \(choice.rawValue)")
      }
    }

    private func store() throws -> UserDefaults {
      try #require(UserDefaults(suiteName: "stored-preference-\(UUID())"))
    }

    @Test("another preference's write renders a direct reader and not the modifier's view")
    func unrelatedWrite() throws {
      let store = try store()
      let (renders, direct) = (Renders(), Renders())
      let screen = OffscreenWindow(
        VStack {
          Reader(renders: renders, chosen: Chosen())
          DirectReader(renders: direct)
        }
        .defaultAppStorage(store), width: 300, height: 200)
      defer { screen.close() }
      let (before, directBefore) = (renders.count, direct.count)
      store.set(1, forKey: "probe.other.preference")
      screen.settle()
      #expect(renders.count == before, "the view rendered for a preference it does not read")
      #expect(direct.count > directBefore, "a dotted key no longer renders its direct reader")
      #expect(try screen.shownText().contains("reader first"))
    }

    @Test("the stored value is shown from the first frame and followed when it changes")
    func followsTheStore() throws {
      let store = try store()
      store.set("second", forKey: Self.key)
      let renders = Renders()
      let screen = OffscreenWindow(
        Reader(renders: renders, chosen: Chosen()).defaultAppStorage(store),
        width: 300, height: 200)
      defer { screen.close() }
      #expect(try screen.shownText() == ["reader second"])
      let before = renders.count
      store.set("first", forKey: Self.key)
      screen.settle()
      #expect(try screen.shownText() == ["reader first"])
      #expect(renders.count == before + 1)
    }

    @Test("what the view sets is stored")
    func writesThrough() throws {
      let store = try store()
      let chosen = Chosen()
      let screen = OffscreenWindow(
        Reader(renders: Renders(), chosen: chosen).defaultAppStorage(store),
        width: 300, height: 200)
      defer { screen.close() }
      chosen.value = .second
      screen.settle()
      #expect(try screen.shownText() == ["reader second"])
      #expect(store.string(forKey: Self.key) == "second")
    }

    @Test("a stored choice that is missing or unknown reads as the default")
    func firstRenderChoice() throws {
      let store = try store()
      #expect(store.choice(Self.key, default: Choice.first) == .first)
      store.set("second", forKey: Self.key)
      #expect(store.choice(Self.key, default: Choice.first) == .second)
      store.set("neither", forKey: Self.key)
      #expect(store.choice(Self.key, default: Choice.first) == .first)
    }

    @Test("the file viewer holds no stored property of its own and follows the stored mode")
    func fileViewer() throws {
      let store = try store()
      let file = WorkspaceFile(
        path: "notes/plan.md", byteCount: 7,
        preview: .text(TextPreview(text: "# Plan\n", lineCount: 1)))
      let viewer = FileViewerView(file: file, source: SampleWorkspaceDataSource())
      // The viewer's keys have dots: a stored property in it would render it for every write.
      let stored = Mirror(reflecting: viewer).children.filter {
        String(describing: type(of: $0.value)).hasPrefix("AppStorage<")
      }
      #expect(stored.isEmpty, "\(stored.map(\.label))")
      let screen = OffscreenWindow(viewer.defaultAppStorage(store), width: 900, height: 400)
      defer { screen.close() }
      #expect(try #require(screen.segmentedPickers.first).selectedSegment == 0)
      store.set("source", forKey: FileViewerView.viewModeKey)
      screen.settle()
      #expect(try #require(screen.segmentedPickers.first).selectedSegment == 1)
      try screen.clickSegment(0, of: try #require(screen.segmentedPickers.first))
      #expect(store.string(forKey: FileViewerView.viewModeKey) == "preview")
    }
  }
#endif
