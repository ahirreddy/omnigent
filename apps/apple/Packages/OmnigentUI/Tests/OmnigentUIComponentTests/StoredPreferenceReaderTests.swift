#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The views whose stored keys have a dot in them render for their own preference only, and
  /// still follow it when it is stored from elsewhere.
  @Suite("Stored preference readers", .serialized)
  @MainActor
  struct StoredPreferenceReaderTests {
    private let bed: InboxTestBed

    /// A key no view reads, with a dot in it as the keys `@AppStorage` cannot watch singly have.
    private static let unreadKey = "omnigent.tests.unread-preference"

    /// The keys for a new line while Return sends, which the sheet lists until the setting is on.
    private static let newlineWhileReturnSends = "⇧Return or ⌥Return"

    init() throws {
      bed = try InboxTestBed()
    }

    private func inbox() -> OffscreenWindow<some View> {
      bed.screen(items: [bed.item("u", age: 20), bed.item("x", age: 30, unread: false)])
    }

    #if DEBUG
      @Test("a preference the Inbox does not read renders neither the list nor its rows")
      func unrelatedWrite() throws {
        let screen = inbox()
        defer { screen.close() }
        let renders = RenderTally.recording {
          bed.store.set(true, forKey: Self.unreadKey)
          screen.settle()
        }
        #expect(renders["inbox"] == nil)
        #expect(renders["inbox row"] == nil)
        #expect(try screen.shows("Preview u"))
        #expect(try screen.shows("Preview x"))
      }

      @Test("the Command-Return setting renders the Inbox's rows and not its list")
      func commandReturnRenders() throws {
        let screen = inbox()
        defer { screen.close() }
        let renders = RenderTally.recording {
          bed.store.set(true, forKey: ComposerPreferences.submitWithCommandReturnKey)
          screen.settle()
        }
        #expect(renders["inbox"] == nil)
        #expect(renders["inbox row"] == 2)
      }
    #endif

    @Test("the filter stored from elsewhere narrows the shown list")
    func filterFollows() throws {
      let screen = inbox()
      defer { screen.close() }
      #expect(try screen.shows("Preview x"))
      bed.store.set(InboxFilter.unread.rawValue, forKey: InboxView.filterKey)
      screen.settle()
      #expect(try screen.shows("Preview u"))
      #expect(try !screen.shows("Preview x"))
      #expect(screen.segmentedControls.first?.selectedSegment == 1)
    }

    @Test("a filter stored before the Inbox opens narrows its list")
    func storedFilter() throws {
      bed.store.set(InboxFilter.unread.rawValue, forKey: InboxView.filterKey)
      let screen = inbox()
      defer { screen.close() }
      #expect(try screen.shows("Preview u"))
      #expect(try !screen.shows("Preview x"))
    }

    @Test("the settings toggle and the shortcuts sheet follow the setting stored from elsewhere")
    func commandReturnFollows() throws {
      let settings = settingsForm(store: bed.store) { ComposerSettingsSection() }
      defer { settings.close() }
      let sheet = OffscreenWindow(
        KeyboardShortcutsSheet().defaultAppStorage(bed.store), width: 560, height: 700)
      defer { sheet.close() }
      #expect(try settings.shows("Return sends; Shift-Return"))
      #expect(try sheet.shows(Self.newlineWhileReturnSends))
      bed.store.set(true, forKey: ComposerPreferences.submitWithCommandReturnKey)
      settings.settle()
      sheet.settle()
      #expect(try settings.shows("Return inserts a new line; Command-Return sends."))
      #expect(try !sheet.shows(Self.newlineWhileReturnSends))
    }
  }
#endif
