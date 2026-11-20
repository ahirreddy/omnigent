import Foundation
import Testing

@testable import OmnigentUIComponents
@testable import OmnigentUITestSupport

@Suite("Inbox triage rules")
struct InboxTriageLogicTests {
  private let now = PreviewData.now

  private func item(
    _ id: String, kind: InboxItem.Kind = .unread, preview: String = "Preview",
    secondsAgo: TimeInterval = 60, decision: DecisionCard? = nil
  ) -> InboxItem {
    InboxItem(
      id: id, kind: kind, sessionId: "session-\(id)", sessionTitle: "Title \(id)",
      preview: preview, date: now.addingTimeInterval(-secondsAgo), decision: decision)
  }

  private func approval(_ id: String, plan: String? = nil) -> DecisionCard {
    var card = DecisionCard(
      id: id, carryingSessionId: "session-\(id)", title: "Allow?", detail: "Details",
      kind: .approval)
    card.permissions.plan = plan
    return card
  }

  @Test("a plan under review can't be approved without opening it; a plain approval can")
  func directApproval() {
    let plain = item("a", kind: .approval, decision: approval("a"))
    #expect(plain.canApprove)
    #expect(plain.approvesDirectly)
    let plan = item("p", kind: .approval, decision: approval("p", plan: "# The plan"))
    #expect(plan.canApprove)
    #expect(!plan.approvesDirectly)
    #expect(!item("u").approvesDirectly)
  }

  @Test("a request without a decision yet is unresolved until answered")
  func unresolved() {
    var waiting = item("q", kind: .question)
    #expect(waiting.isUnresolved)
    #expect(!waiting.canApprove)
    waiting.phase = .answered(summary: "Done")
    #expect(!waiting.isUnresolved)
    #expect(!item("c", kind: .comment).isUnresolved)
    #expect(!item("u", kind: .unread).isUnresolved)
    var resolving = item("r", kind: .unread)
    resolving.phase = .resolving
    #expect(resolving.isUnresolved)
  }

  @Test("each kind and filter has its label")
  func labels() {
    let kinds: [InboxItem.Kind] = [
      .approval, .question, .comment, .unread, .suggestion, .automationFailure,
    ]
    #expect(
      kinds.map(\.title) == [
        "Approval needed", "Question", "Comment", "Unread", "Suggestion", "Automation failed",
      ])
    #expect(InboxFilter.allCases.map(\.title) == ["All", "Unread", "Needs you", "Omni Advisor"])
    #expect(InboxFilter.allCases.map(\.id) == InboxFilter.allCases)
  }

  @Test("search finds what the row shows, whichever field holds it")
  func searchFields() {
    var titled = item("titled", kind: .approval, preview: "", decision: approval("titled"))
    titled.decision?.title = "Delete the production bucket"
    var comment = item("comment", kind: .comment, preview: "")
    comment.comment = InboxComment(author: "Rosalind", path: "src/app.rs", body: "Why the retry?")
    var context = item("context")
    context.agentName = "Codex"
    context.executionContext = "Build Mac"
    let items = [titled, comment, context]
    func found(_ query: String) -> [String] {
      InboxTriage.items(items, filter: .all, search: query, now: now).map(\.id)
    }
    #expect(found("production") == ["titled"], "the headline of a request with no preview")
    #expect(found("rosalind") == ["comment"])
    #expect(found("RETRY") == ["comment"])
    #expect(found("app.rs") == ["comment"])
    #expect(found("codex") == ["context"])
    #expect(found("build mac") == ["context"])
    #expect(found("Title context") == ["context"])
    #expect(found("   \n") == ["titled", "comment", "context"], "blank search keeps everything")
    #expect(found("no such thing").isEmpty)
    #expect(found("\u{202E}\u{0}").isEmpty)
  }

  @Test("the count pill counts requests, comments and unread, with singular forms")
  func summary() {
    let many = [
      item("a", kind: .approval), item("b", kind: .question), item("c", kind: .comment),
      item("d", kind: .comment), item("e"), item("f"),
    ]
    #expect(InboxTriage.summary(many) == "2 approvals \u{00B7} 2 comments \u{00B7} 2 unread")
    #expect(InboxTriage.summary([item("a", kind: .question)]) == "1 approval")
    #expect(InboxTriage.summary([item("c", kind: .comment)]) == "1 comment")
    #expect(InboxTriage.summary([item("e")]) == "1 unread")
  }

  @Test("chart values read as the web prints them")
  func chartValues() {
    #expect(InboxChartView.format(12, unit: "ms") == "12 ms")
    #expect(InboxChartView.format(40, unit: "%") == "40%")
    #expect(InboxChartView.format(1.5, unit: nil) == "1.5")
    #expect(InboxChartView.format(1.257, unit: "") == "1.26")
    #expect(InboxChartView.format(0.999, unit: nil) == "1")
  }

  @Test("the pill counts failed automations and suggestions, with the unread total")
  func feedSummary() {
    let items = [
      item("a", kind: .automationFailure), item("b", kind: .suggestion),
      item("c", kind: .suggestion),
    ]
    #expect(
      InboxTriage.summary(items, unreadSuggestions: 1)
        == "1 failed automation \u{00B7} 2 suggestions (1 unread)")
    #expect(
      InboxTriage.summary(items, unreadSuggestions: 100, unreadSuggestionsCapped: true)
        == "1 failed automation \u{00B7} 2 suggestions (100+ unread)")
    #expect(
      InboxTriage.summary([item("a", kind: .automationFailure), item("d", kind: .suggestion)])
        == "1 failed automation \u{00B7} 1 suggestion")
  }

  @Test("agent items and failures show under All and Unread, never under Needs you")
  func feedFilters() {
    var read = item("read", kind: .suggestion)
    read.isUnread = false
    let items = [item("unread", kind: .suggestion), read, item("failed", kind: .automationFailure)]
    func shown(_ filter: InboxFilter) -> Set<String> {
      Set(InboxTriage.items(items, filter: filter, search: "", now: now).map(\.id))
    }
    #expect(shown(.all) == ["unread", "read", "failed"])
    #expect(shown(.unread) == ["unread", "failed"])
    #expect(shown(.awaiting).isEmpty)
    var suggestion = item("s", kind: .suggestion, preview: "")
    suggestion.suggestion = InboxSuggestion(
      kindLabel: "Reminder", title: "Renew the certificate", body: "It expires on Friday.")
    var failure = item("f", kind: .automationFailure, preview: "")
    failure.automationFailure = InboxAutomationFailure(
      automationID: "t1", name: "Nightly sync", reason: "Host \u{00B7} The host was offline.")
    let found = { (query: String) in
      InboxTriage.items([suggestion, failure], filter: .all, search: query, now: now).map(\.id)
    }
    #expect(found("certificate") == ["s"])
    #expect(found("friday") == ["s"])
    #expect(found("nightly") == ["f"])
    #expect(found("offline") == ["f"])
  }

  @Test("Omni Advisor's tab lists only its items, and shows only while it runs for the caller")
  func advisorTab() {
    var advisor = item("advisor", kind: .suggestion)
    advisor.suggestion = InboxSuggestion(
      kindLabel: "Omni Advisor \u{00B7} Reminder", title: "Renew", body: "", isAdvisor: true)
    var other = item("other", kind: .suggestion)
    other.suggestion = InboxSuggestion(kindLabel: "Reminder", title: "Ship", body: "")
    let items = [advisor, other, item("approval", kind: .approval, decision: approval("a"))]
    func shown(_ filter: InboxFilter) -> [String] {
      InboxTriage.items(items, filter: filter, search: "", now: now).map(\.id)
    }
    #expect(shown(.advisor) == ["advisor"])
    #expect(Set(shown(.all)) == ["advisor", "other", "approval"], "All keeps the advisor's items")

    let base: [InboxFilter] = [.all, .unread, .awaiting]
    #expect(InboxFilter.offered(advisorTab: .shown, chosen: .all) == base + [.advisor])
    #expect(InboxFilter.offered(advisorTab: .hidden, chosen: .advisor) == base)
    // While the settings load, the tab stays only where it was already chosen.
    #expect(InboxFilter.offered(advisorTab: .loading, chosen: .advisor) == base + [.advisor])
    #expect(InboxFilter.offered(advisorTab: .loading, chosen: .unread) == base)
    #expect(InboxFilter.effective(.advisor, advisorTab: .hidden) == .all)
    #expect(InboxFilter.effective(.advisor, advisorTab: .shown) == .advisor)
    #expect(InboxFilter.effective(.unread, advisorTab: .hidden) == .unread)
  }

  @Test(
    "group boundaries, and no header ever repeats", arguments: [0.0, 1, 3_600, 90_000, 500_000])
  func groupHeadersAreUnique(offset: TimeInterval) {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = .gmt
    let reference = now.addingTimeInterval(offset)
    let items = [-86_400.0, 10, 299, 300, 7_000, 90_000, 200_000, 600_000, 9_000_000].enumerated()
      .map { index, age in
        InboxItem(
          id: "\(index)", kind: .unread, sessionId: "s", sessionTitle: "t", preview: "p",
          date: reference.addingTimeInterval(-age))
      }
    let titles = InboxTriage.groups(items, now: reference, calendar: utc).map(\.title)
    #expect(Set(titles).count == titles.count, "\(titles)")
    #expect(titles.first == "Just now", "an item dated later than now is new, not lost")
    #expect(titles.last == "Older")
  }

  @Test("same-time items keep the order the adapter gave them")
  func stableOrder() {
    let items = ["c", "a", "b"].map { item($0, secondsAgo: 10) }
    #expect(InboxTriage.groups(items, now: now).flatMap(\.items).map(\.id) == ["c", "a", "b"])
  }

  @Test("selection with nothing to keep falls to the first actionable item, then the first item")
  func selectionFallbacks() {
    let request = item("r", kind: .approval, secondsAgo: 120, decision: approval("r"))
    let unread = item("u")
    #expect(InboxTriage.selection(nil, previous: [], current: [unread, request]) == "r")
    #expect(InboxTriage.selection(nil, previous: [], current: [unread]) == "u")
    #expect(InboxTriage.selection(nil, previous: [], current: []) == nil)
    #expect(InboxTriage.selection("gone", previous: [], current: [unread]) == "u")
    #expect(InboxTriage.selection("u", previous: [unread], current: [unread, request]) == "u")
    var readOnly = request
    readOnly.isReadOnly = true
    #expect(InboxTriage.selection(nil, previous: [], current: [readOnly, unread]) == "r")
  }

  @Test("moving past either end stays there, even by a huge step or from a stale id")
  func moveExtremes() {
    let items = [item("a"), item("b"), item("c")]
    #expect(InboxTriage.move("a", by: 1, in: items) == "b")
    #expect(InboxTriage.move("c", by: -1, in: items) == "b")
    #expect(InboxTriage.move("b", by: 1_000, in: items) == "c")
    #expect(InboxTriage.move("b", by: -1_000, in: items) == "a")
    #expect(InboxTriage.move("gone", by: 1, in: items) == "a")
  }
}
