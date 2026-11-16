#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// A kept tab is one view wherever it goes: whole, in a pane of a split, or out of sight. So a
  /// split, and the way back from one, places tabs and builds none.
  @MainActor
  @Suite("Kept-alive tabs in a split")
  struct KeptAliveTabsPaneTests {
    private struct Tab: Identifiable {
      let id: String
    }

    /// What each tab's content last saw, and how often it was built.
    private final class Seen {
      var frames: [String: CGRect] = [:]
      var isActive: [String: Bool] = [:]
      var isHidden: [String: Bool] = [:]
      var builds: [String: Int] = [:]
    }

    private struct Probe: View {
      let id: String
      let seen: Seen
      @Environment(\.isActiveTabPane) private var isActive
      @Environment(\.isTabContentHidden) private var isHidden

      var body: some View {
        Color.clear
          .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named("column"))
          } action: { frame in
            seen.frames[id] = frame
          }
          .onChange(of: isActive, initial: true) { seen.isActive[id] = isActive }
          .onChange(of: isHidden, initial: true) { seen.isHidden[id] = isHidden }
          .onAppear { seen.builds[id, default: 0] += 1 }
      }
    }

    private func tabs(
      _ places: KeyValuePairs<String, KeptTabPlace>, fraction: Double = 0.4, hinge: CGRect? = nil,
      seen: Seen
    ) -> some View {
      let byID = Dictionary(uniqueKeysWithValues: places.map { ($0.key, $0.value) })
      return KeptAliveTabs(
        places.map { Tab(id: $0.key) }, fraction: fraction, hinge: hinge,
        place: { byID[$0.id] ?? .hidden },
        content: { Probe(id: $0.id, seen: seen) }
      )
      .coordinateSpace(.named("column"))
    }

    private func layOut(_ view: NSView, at size: CGSize) {
      view.frame = CGRect(origin: .zero, size: size)
      view.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private let column = CGSize(width: 1_001, height: 600)
    private var bounds: CGRect { CGRect(origin: .zero, size: column) }

    @Test("Each pane's tab takes its pane; a hidden tab keeps the column; one pane is active")
    func panes() {
      _ = NSApplication.shared
      let seen = Seen()
      let view = NSHostingView(
        rootView: tabs(
          [
            "left": .pane(.leading, isFocused: true), "right": .pane(.trailing, isFocused: false),
            "behind": .hidden,
          ], seen: seen))
      layOut(view, at: column)

      let panes = TabSplitLayout(width: column.width, fraction: 0.4)
      #expect(seen.frames["left"] == panes.frame(of: .leading, in: bounds))
      #expect(seen.frames["right"] == panes.frame(of: .trailing, in: bounds))
      #expect(seen.frames["behind"] == bounds)
      #expect(seen.isActive == ["left": true, "right": false, "behind": false])
      #expect(seen.isHidden == ["left": false, "right": false, "behind": true])
    }

    @Test("On an unfolded device the panes sit either side of the hinge")
    func hinge() {
      _ = NSApplication.shared
      let seen = Seen()
      let hinge = CGRect(x: 420, y: 0, width: 20, height: 600)
      let view = NSHostingView(
        rootView: tabs(
          ["left": .pane(.leading, isFocused: false), "right": .pane(.trailing, isFocused: true)],
          hinge: hinge, seen: seen))
      layOut(view, at: CGSize(width: 860, height: 600))

      #expect(seen.frames["left"] == CGRect(x: 0, y: 0, width: 420, height: 600))
      #expect(seen.frames["right"] == CGRect(x: 440, y: 0, width: 420, height: 600))
      #expect(seen.isActive == ["left": false, "right": true])
    }

    @Test("Splitting, moving focus, unsplitting and showing another tab build no tab again")
    func sameViews() {
      _ = NSApplication.shared
      let seen = Seen()
      let view = NSHostingView(
        rootView: tabs(["one": .whole, "two": .hidden, "three": .hidden], seen: seen))
      layOut(view, at: column)
      #expect(seen.frames["one"] == bounds)

      let panes = TabSplitLayout(width: column.width, fraction: 0.4)
      view.rootView = tabs(
        [
          "one": .pane(.leading, isFocused: true), "two": .pane(.trailing, isFocused: false),
          "three": .hidden,
        ], seen: seen)
      layOut(view, at: column)
      #expect(seen.frames["one"] == panes.frame(of: .leading, in: bounds))
      #expect(seen.frames["two"] == panes.frame(of: .trailing, in: bounds))
      #expect(seen.isHidden == ["one": false, "two": false, "three": true])

      view.rootView = tabs(
        [
          "one": .pane(.leading, isFocused: false), "two": .pane(.trailing, isFocused: true),
          "three": .hidden,
        ], seen: seen)
      layOut(view, at: column)
      #expect(seen.isActive == ["one": false, "two": true, "three": false])

      // Too narrow for both, or the split closed: the focused pane's tab takes the column.
      view.rootView = tabs(["one": .hidden, "two": .whole, "three": .hidden], seen: seen)
      layOut(view, at: column)
      #expect(seen.frames["two"] == bounds)
      #expect(seen.isHidden == ["one": true, "two": false, "three": true])

      view.rootView = tabs(["one": .hidden, "two": .hidden, "three": .whole], seen: seen)
      layOut(view, at: column)
      #expect(seen.isActive == ["one": false, "two": false, "three": true])
      #expect(seen.builds == ["one": 1, "two": 1, "three": 1])
    }

    @Test("Moving the divider places the panes again and leaves a hidden tab as it was")
    func layoutCalls() {
      _ = NSApplication.shared
      let seen = Seen()
      let split: KeyValuePairs<String, KeptTabPlace> = [
        "one": .pane(.leading, isFocused: true), "two": .pane(.trailing, isFocused: false),
        "three": .hidden,
      ]
      let view = NSHostingView(rootView: tabs(split, seen: seen))
      layOut(view, at: column)
      let calls = LayoutTally.recording {
        view.rootView = tabs(split, fraction: 0.5, seen: seen)
        layOut(view, at: column)
      }
      #expect(calls["kept tabs place", default: 0] >= 1)
      #expect(seen.frames["one"]?.width == 500)
      #expect(seen.frames["three"] == bounds, "the hidden tab stays as it was")
    }
  }

  @MainActor
  @Suite("Layout tally")
  struct LayoutTallyTests {
    private struct Failure: Error {}

    @Test("Layout calls count by name while a test records them, and not otherwise")
    func records() {
      LayoutTally.count("before")
      let calls = LayoutTally.recording {
        LayoutTally.count("measure")
        LayoutTally.count("measure")
        LayoutTally.count("place")
      }
      #expect(calls == ["measure": 2, "place": 1])
      LayoutTally.count("after")
      #expect(LayoutTally.recording {}.isEmpty, "each recording starts empty")
    }

    @Test("A change that throws stops the recording")
    func stopsWhenTheChangeThrows() {
      #expect(throws: Failure.self) {
        try LayoutTally.recording { throw Failure() }
      }
      LayoutTally.count("after")
      #expect(LayoutTally.recording {}.isEmpty)
    }
  }
#endif
