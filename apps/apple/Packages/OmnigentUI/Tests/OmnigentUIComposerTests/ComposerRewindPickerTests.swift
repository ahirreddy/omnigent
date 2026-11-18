#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The `/rewind` picker: its states, search, choosing a prompt and loading older ones.
  @Suite("Composer: rewind picker", .serialized)
  @MainActor
  struct ComposerRewindPickerTests {
    private final class Log {
      var events: [String] = []
    }
    private let log = Log()

    private let prompts = [
      RewindPickerState.Prompt(id: "msg_3", text: "Add a test for the parser"),
      RewindPickerState.Prompt(id: "msg_2", text: ""),
      RewindPickerState.Prompt(id: "msg_1", text: "Fix the parser"),
    ]

    private func open(_ state: RewindPickerState) -> OffscreenWindow<RewindPickerSheet> {
      let log = log
      return OffscreenWindow(
        RewindPickerSheet(
          state: state,
          actions: RewindPickerActions(
            choose: { log.events.append("choose:\($0)") },
            loadOlder: { log.events.append("older") },
            dismiss: { log.events.append("dismiss") })))
    }

    @Test("prompts list newest first under the web's heading, an attachment-only one by name")
    func lists() throws {
      let screen = open(RewindPickerState(phase: .loaded, prompts: prompts, older: .available))
      defer { screen.close() }
      #expect(try screen.shows("Continue from just before"))
      #expect(try screen.shows("Add a test for the parser"))
      #expect(try screen.shows("(attachment)"))
      #expect(try screen.shows("Load older prompts"))
    }

    @Test("loading, failure and an empty session each say so")
    func states() throws {
      let loading = open(RewindPickerState(phase: .loading))
      defer { loading.close() }
      #expect(try loading.shows("Loading prompts\u{2026}"))
      let failed = open(RewindPickerState(phase: .failed("Could not load prompts")))
      defer { failed.close() }
      #expect(try failed.shows("Could not load prompts"))
      let empty = open(RewindPickerState(phase: .loaded))
      defer { empty.close() }
      #expect(try empty.shows("No prompts to rewind to"))
      let olderFailed = open(
        RewindPickerState(phase: .loaded, prompts: prompts, older: .failed("Offline")))
      defer { olderFailed.close() }
      #expect(try olderFailed.shows("Offline \u{2014} try again"))
    }

    @Test("Return chooses the first prompt the search matches, and Esc cancels")
    func searchAndKeys() throws {
      let screen = open(RewindPickerState(phase: .loaded, prompts: prompts))
      defer { screen.close() }
      try screen.type("fix", intoField: 0)
      try screen.pressReturn()
      #expect(log.events == ["choose:msg_1"])
      #expect(try screen.pressShortcut(keyCode: 53, characters: "\u{1B}", modifiers: []))
      #expect(log.events.last == "dismiss")
    }

    @Test("search matches every word in any case; a blank search keeps them all")
    func matching() {
      #expect(RewindPickerState.matching(prompts, query: "").count == 3)
      #expect(RewindPickerState.matching(prompts, query: "PARSER test").map(\.id) == ["msg_3"])
      #expect(RewindPickerState.matching(prompts, query: "nothing").isEmpty)
      #expect(RewindPickerSheet.label(prompts[1]) == "(attachment)")
    }
  }
#endif
