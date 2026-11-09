#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Automations guide, clicked", .serialized)
  @MainActor
  struct PagesIntroTests {
    private let log = ActionLog()

    private func guide(
      sessionModes: Bool = true, sandboxes: Bool = true, triggers: Bool = true
    ) -> OffscreenWindow<AutomationsIntro> {
      SystemSideEffects.reset()
      let log = log
      return OffscreenWindow(
        AutomationsIntro(
          steps: AutomationsIntro.steps(
            sessionModes: sessionModes, sandboxes: sandboxes, triggers: triggers),
          dismiss: { log.record("dismiss") }), width: 800, height: 600)
    }

    @Test("only the steps the server supports are offered")
    func steps() {
      func ids(_ modes: Bool, _ triggers: Bool) -> [String] {
        AutomationsIntro.steps(sessionModes: modes, sandboxes: false, triggers: triggers).map(\.id)
      }
      #expect(ids(false, false) == ["schedule", "configure"])
      #expect(ids(true, false) == ["schedule", "context", "configure"])
      #expect(ids(true, true) == ["schedule", "watch", "context", "configure"])
      let plain = AutomationsIntro.steps(sessionModes: false, sandboxes: false).last
      let sandboxed = AutomationsIntro.steps(sessionModes: false, sandboxes: true).last
      #expect(plain?.checklist.contains("Connected computer") == true)
      #expect(sandboxed?.checklist.contains("Computer or sandbox") == true)
    }

    @Test("Next walks to the end, where it becomes Done and dismisses")
    func walkThrough() throws {
      let screen = guide()
      defer { screen.close() }
      #expect(try screen.shows("1 of 4 \u{00B7} Run on a schedule"))
      let next = try #require(screen.controlFrames.last)
      let point = CGPoint(x: next.midX, y: next.midY)
      try screen.click(point)
      #expect(try screen.shows("2 of 4 \u{00B7} Watch for new work"))
      try screen.click(point)
      #expect(try screen.shows("3 of 4"))
      #expect(try screen.shows("Earlier work"))
      #expect(try !screen.shows("Done"))
      try screen.click(point)
      #expect(try screen.shows("4 of 4"))
      #expect(try screen.shows("Your automation"))
      #expect(log.entries.isEmpty)
      let done = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: done.midX, y: done.midY))
      #expect(log.entries == ["dismiss"])
    }

    @Test("clicking a step goes straight to it")
    func jump() throws {
      let screen = guide()
      defer { screen.close() }
      try screen.clickControl(at: 2)
      #expect(try screen.shows("3 of 4 \u{00B7} Keep context between runs"))
      try screen.clickControl(at: 0)
      #expect(try screen.shows("1 of 4"))
    }

    @Test("Maybe later dismisses from any step")
    func later() throws {
      let screen = guide()
      defer { screen.close() }
      let frames = screen.controlFrames
      let later = frames[frames.count - 2]
      try screen.click(CGPoint(x: later.midX, y: later.midY))
      #expect(log.entries == ["dismiss"])
    }

    @Test("no steps at all still draws, with Done dismissing")
    func noSteps() throws {
      SystemSideEffects.reset()
      let log = log
      let screen = OffscreenWindow(
        AutomationsIntro(steps: [], dismiss: { log.record("dismiss") }), width: 800, height: 600)
      defer { screen.close() }
      let done = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: done.midX, y: done.midY))
      #expect(log.entries == ["dismiss"])
    }
  }

  @Suite("Usage page, clicked", .serialized)
  @MainActor
  struct PagesUsageViewTests {
    private let log = ActionLog()
    private let now = Date(timeIntervalSince1970: 1_793_880_000)

    private var actions: UsageActions {
      let log = log
      var actions = UsageActions(formatCost: { String(describing: $0) })
      actions.setRange = { range, _, _ in log.record("range \(range.rawValue)") }
      actions.openSession = { log.record("open \($0)") }
      actions.retry = { log.record("retry") }
      return actions
    }

    private func session(_ id: String, cost: Double, age: TimeInterval = 60) -> UsageSessionRow {
      UsageSessionRow(
        id: id, title: "Session \(id)", model: "Opus", harness: "Claude", updatedAt: .now - age,
        costUSD: cost, costText: "$\(cost)")
    }

    private func page(
      _ state: UsageViewState, actions: UsageActions? = nil
    ) -> OffscreenWindow<UsageView> {
      SystemSideEffects.reset()
      return OffscreenWindow(
        UsageView(state: state, actions: actions ?? self.actions), width: 900, height: 1_100)
    }

    @Test("the range buttons report the range chosen, and Custom offers dates")
    func range() throws {
      let screen = page(UsageViewState())
      defer { screen.close() }
      let picker = try #require(screen.segmentedControls.first)
      #expect(screen.allViews.compactMap { $0 as? NSDatePicker }.isEmpty)
      try screen.click(segment: 0, of: picker)
      #expect(log.entries == ["range week"])
      try screen.click(segment: 3, of: picker)
      #expect(log.entries.last == "range all")
      try screen.click(segment: 4, of: picker)
      #expect(log.entries.last == "range custom")
      #expect(screen.allViews.compactMap { $0 as? NSDatePicker }.count == 2)
    }

    @Test("a start after the end drags the end along, so the range is never backwards")
    func customDates() throws {
      let dates = EditedValue<[Date]>([])
      var actions = actions
      actions.setRange = { _, start, end in dates.value = [start, end] }
      let screen = page(UsageViewState(), actions: actions)
      defer { screen.close() }
      try screen.click(segment: 4, of: try #require(screen.segmentedControls.first))
      let pickers = screen.allViews.compactMap { $0 as? NSDatePicker }
      let from = try #require(pickers.first)
      from.dateValue = Date.now.addingTimeInterval(-86_400)
      _ = from.sendAction(from.action, to: from.target)
      screen.settle()
      let reported = dates.value
      #expect(reported.count == 2)
      #expect(reported.first.map { $0 <= reported[1] } == true)
    }

    @Test("a failed report offers Retry and hides the numbers")
    func failed() throws {
      let screen = page(UsageViewState(loadError: "Server down"))
      defer { screen.close() }
      #expect(try screen.shows("Failed to load usage data"))
      #expect(try screen.shows("Server down"))
      #expect(try !screen.shows("Total cost"))
      let retry = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: retry.midX, y: retry.midY))
      #expect(log.entries == ["retry"])
    }

    @Test("loading hides the numbers; no data says so in each section")
    func emptyStates() throws {
      let loading = page(UsageViewState(isLoading: true))
      defer { loading.close() }
      #expect(try !loading.shows("Total cost"))
      let empty = page(UsageViewState())
      defer { empty.close() }
      #expect(try empty.shows("$0.00"))
      #expect(try empty.shows("0 sessions"))
      #expect(try empty.shows("No spend recorded in this range"))
      #expect(try empty.shows("No data"))
      #expect(try empty.shows("No sessions in this range"))
    }

    @Test("one session reads in the singular")
    func singular() throws {
      let screen = page(UsageViewState(totalText: "$1.50", sessions: [session("a", cost: 1.5)]))
      defer { screen.close() }
      #expect(try screen.shows("$1.50"))
      #expect(try screen.shows("1 session"))
      #expect(try !screen.shows("1 sessions"))
    }

    @Test("costs that aren't numbers or are enormous draw without crashing or hanging")
    func nonFiniteCosts() throws {
      let amounts = [Double.nan, .infinity, -.infinity, -1, 0, 1e300].enumerated().map {
        UsageAmount(label: "2026-11-0\($0.offset + 1)", costUSD: $0.element)
      }
      let screen = page(
        UsageViewState(
          totalText: "$1.00", daily: amounts, byHarness: amounts, byModel: amounts,
          sessions: [session("a", cost: .nan), session("b", cost: .infinity)]))
      defer { screen.close() }
      #expect(try screen.shows("Daily cost"))
    }

    @Test("hovering the chart names that day and its cost")
    func hoverChart() throws {
      let screen = OffscreenWindow(
        UsageDailyChart(
          daily: [
            UsageAmount(label: "2026-11-01", costUSD: 3.5),
            UsageAmount(label: "2026-11-02", costUSD: 7.25),
          ],
          formatCost: { "cost \($0)" }
        ).frame(width: 400, height: 200), width: 400, height: 200)
      defer { screen.close() }
      #expect(try !screen.shows("cost 7.25"))
      try screen.hover(CGPoint(x: 300, y: 100))
      screen.settle(0.3)
      #expect(try screen.shows("cost 7.25"))
      #expect(try !screen.shows("cost 3.5"))
    }

    @Test("a report of only unreadable days still draws its section")
    func unreadableDays() throws {
      let screen = page(UsageViewState(daily: [UsageAmount(label: "not-a-day", costUSD: 1)]))
      defer { screen.close() }
      #expect(try screen.shows("Daily cost"))
    }

    @Test("the table lists sessions and clicking a title opens that one")
    func table() throws {
      let screen = page(
        UsageViewState(sessions: [session("a", cost: 1), session("b", cost: 9, age: 500)]))
      defer { screen.close() }
      let table = try #require(screen.allViews.compactMap { $0 as? NSTableView }.first)
      #expect(table.numberOfRows == 2)
      let rect = table.frameOfCell(atColumn: 0, row: 1)
      let point = table.convert(CGPoint(x: rect.minX + 20, y: rect.midY), to: screen.host)
      try screen.click(point)
      #expect(log.entries == ["open b"])
    }

    @Test("the phone list's rows open their session, and its menu changes the sort")
    func phoneList() throws {
      let order = EditedValue([KeyPathComparator(\UsageSessionRow.updatedAt, order: .reverse)])
      let rows = [session("a", cost: 1), session("b", cost: 9)]
      SystemSideEffects.reset()
      let log = log
      let screen = OffscreenWindow(
        UsageSessionList(
          sessions: rows, sortOrder: order.binding, openSession: { log.record("open \($0)") }),
        width: 400, height: 300)
      defer { screen.close() }
      try screen.choose("Cost", inPopUp: try #require(screen.popUps.first))
      #expect(UsageSessionSort(order.value) == .cost)
      try screen.clickControl(at: 2)
      #expect(log.entries == ["open b"])
      #expect(try screen.shows("$9.0"))
    }

    @Test("the phone list's rows can't be clicked with nowhere to open them")
    func phoneListReadOnly() throws {
      SystemSideEffects.reset()
      let order = EditedValue([KeyPathComparator(\UsageSessionRow.updatedAt, order: .reverse)])
      let screen = OffscreenWindow(
        UsageSessionList(
          sessions: [session("a", cost: 1)], sortOrder: order.binding, openSession: nil),
        width: 400, height: 300)
      defer { screen.close() }
      #expect(screen.controlFrames.count == 1, "only the sort menu")
    }
  }
#endif
