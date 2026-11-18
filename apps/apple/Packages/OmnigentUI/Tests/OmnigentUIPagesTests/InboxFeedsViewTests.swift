#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// Agent-posted items and automation failures in the Inbox: what a row and its card show,
  /// opening one marks it read, and each feed's failure and paging.
  @Suite("Inbox feeds", .serialized)
  @MainActor
  struct InboxFeedsViewTests {
    private let bed: InboxTestBed

    init() throws {
      bed = try InboxTestBed()
    }

    private var actions: InboxActions {
      var actions = bed.actions
      let log = bed.log
      actions.takeSuggestionAction = { log.record("action \($0.id) \($1)") }
      actions.dismissSuggestion = { log.record("dismiss \($0.id) \($1.id)") }
      actions.openLink = { log.record("link \($0.id)") }
      actions.openSource = { log.record("source \($0.sessionId)") }
      actions.openAutomation = { log.record("automation \($0.id)") }
      actions.retrySuggestions = { log.record("retry suggestions") }
      actions.loadMoreSuggestions = { log.record("more suggestions") }
      actions.retryAutomations = { log.record("retry automations") }
      actions.loadMoreAutomations = { log.record("more automations") }
      return actions
    }

    private func suggestion(unread: Bool = true) -> InboxItem {
      var item = bed.item("s1", kind: .suggestion, unread: unread)
      item.preview = "It expires on Friday."
      item.agentName = "Ops agent"
      item.suggestion = InboxSuggestion(
        kindLabel: "Reminder", title: "Renew the certificate",
        body: "It expires on **Friday**.",
        links: [InboxLink(title: "Open session", sessionID: "abc")],
        actions: ["Renew it", "Later"], sourceTitle: "Cert rotation",
        dismissChoices: [InboxDismissChoice(id: "not_now", title: "Not now")])
      return item
    }

    private func failure() -> InboxItem {
      var item = bed.item("f1", kind: .automationFailure)
      item.preview = "Host \u{00B7} The host was offline."
      item.automationFailure = InboxAutomationFailure(
        automationID: "t1", name: "Nightly sync", reason: "Host \u{00B7} The host was offline.")
      return item
    }

    @Test("an agent's item shows its kind, body, source, Dismiss and actions")
    func suggestionCard() throws {
      let screen = bed.screen(InboxViewState(items: [suggestion()]), actions: actions)
      defer { screen.close() }
      screen.settle(0.3)
      let shown = try screen.shownText().joined(separator: "\n")
      for text in [
        "Reminder", "Renew the certificate", "Source", "Open session", "Posted from",
        "Cert rotation", "Dismiss", "Renew it", "Later",
      ] {
        #expect(shown.contains(text), "\(text) in \(shown)")
      }
      #expect(!shown.contains("Last activity"), "an agent's item shows only its age")
    }

    @Test("opening an unread agent item marks it read; a read one is left alone")
    func openingMarksRead() throws {
      for unread in [true, false] {
        let marked = bed.log.entries.count { $0 == "read s1" }
        let screen = bed.screen(
          InboxViewState(items: [suggestion(unread: unread)]), actions: actions)
        defer { screen.close() }
        _ = screen.restingControlFrames()
        let row = try #require(screen.buttonFrames.first { $0.width > 200 && $0.height < 200 })
        // The selected row opens by itself; the first click closes it and the second opens it.
        try screen.click(row.center)
        screen.settle(0.3)
        try screen.click(row.center)
        screen.settle(0.3)
        let markedNow = bed.log.entries.count { $0 == "read s1" }
        #expect(markedNow == marked + (unread ? 1 : 0), "\(bed.log.entries)")
      }
    }

    @Test("a failed automation shows why, Open automation and Mark as read")
    func failureCard() throws {
      let screen = bed.screen(InboxViewState(items: [failure()]), actions: actions)
      defer { screen.close() }
      screen.settle(0.3)
      let shown = try screen.shownText().joined(separator: "\n")
      for text in [
        "Automation failed", "Nightly sync", "The host was offline.", "Open automation",
        "Mark as read",
      ] {
        #expect(shown.contains(text), "\(text) in \(shown)")
      }
    }

    @Test("each feed's failure and paging have their words")
    func feedBanners() throws {
      var state = InboxViewState(items: [suggestion(), failure()])
      state.suggestionsFailed = true
      state.automationsFailed = true
      state.suggestionWriteFailed = true
      state.hasMoreSuggestions = true
      state.hasMoreAutomations = true
      let screen = bed.screen(state, actions: actions)
      defer { screen.close() }
      screen.settle(0.3)
      let shown = try screen.shownText().joined(separator: "\n")
      for text in [
        "Couldn\u{2019}t load suggestions.", "Retry suggestions",
        "Couldn\u{2019}t load automation failures.", "Retry automations",
        "Couldn\u{2019}t save your response to this suggestion. Try again.",
        "Load more suggestions", "Check more automations",
      ] {
        #expect(shown.contains(text), "\(text) in \(shown)")
      }
    }

    @Test("with only older feed pages left, the empty list says so")
    func emptyWithMore() throws {
      var state = InboxViewState(items: [])
      state.hasMoreAutomations = true
      let screen = bed.screen(state, actions: actions)
      defer { screen.close() }
      #expect(try screen.shows("Nothing waiting in the loaded items"))
    }
  }
#endif
