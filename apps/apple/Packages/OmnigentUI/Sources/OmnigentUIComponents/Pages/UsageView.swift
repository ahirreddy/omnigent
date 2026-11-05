import Charts
public import SwiftUI

/// The Usage page (the web's `/usage`): total spend for a date range, daily cost, cost by
/// harness and model, and the sessions table.
public struct UsageView: View {
  private let state: UsageViewState
  private let actions: UsageActions
  @State private var range: UsageRange = .month
  @State private var start = Calendar.current.date(byAdding: .day, value: -29, to: .now) ?? .now
  @State private var end = Date.now
  @State private var sortOrder = [KeyPathComparator(\UsageSessionRow.updatedAt, order: .reverse)]
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPhone width: the header, breakdowns and sessions stack instead of sitting side by side.
    private var isCompact: Bool { sizeClass == .compact }
  #else
    private let isCompact = false
  #endif

  /// Creates the page.
  public init(state: UsageViewState, actions: UsageActions) {
    self.state = state
    self.actions = actions
  }

  /// The page.
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.section) {
        header
        if let error = state.loadError {
          VStack(spacing: Theme.Spacing.small) {
            Label("Failed to load usage data", systemImage: "exclamationmark.triangle")
            Text(error).font(.caption).foregroundStyle(.secondary)
            if let retry = actions.retry { Button("Retry", action: retry) }
          }
          .frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.section)
          .accessibilityIdentifier("usage-load-error")
        } else if state.isLoading {
          ProgressView().frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.section)
        } else {
          total
          section("Daily cost") { dailyChart }
          let breakdowns =
            isCompact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.section))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Spacing.large))
          breakdowns {
            section("Cost by harness") { breakdown(state.byHarness) }
            section("Cost by model") { breakdown(state.byModel) }
          }
          section("Sessions") { sessions }
        }
      }
      .padding(Theme.Spacing.gutter)
      .frame(maxWidth: Theme.inboxWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .themeCanvas()
    .navigationTitle("Usage")
    .onChange(of: range) { report() }
    .onChange(of: start) { report() }
    .onChange(of: end) { report() }
  }

  private func report() {
    if start > end { end = start }
    actions.setRange?(range, start, end)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      if isCompact {
        Text("Usage").font(.largeTitle.weight(.semibold))
        rangePicker
      } else {
        HStack {
          Text("Usage").font(.largeTitle.weight(.semibold))
          Spacer()
          rangePicker.fixedSize()
        }
      }
      if range == .custom {
        let dates =
          isCompact ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
        dates {
          DatePicker("From", selection: $start, in: ...end, displayedComponents: .date)
          DatePicker("to", selection: $end, in: start...Date.now, displayedComponents: .date)
        }
        .fixedSize()
        .accessibilityIdentifier("usage-custom-range")
      }
    }
  }

  private var rangePicker: some View {
    Picker("Range", selection: $range) {
      ForEach(UsageRange.allCases) { Text($0.title).tag($0) }
    }
    .pickerStyle(.segmented)
    .accessibilityIdentifier("usage-range")
  }

  private var total: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      Text("Total cost").font(.caption).foregroundStyle(.secondary)
      Text(state.totalText).font(.title.weight(.semibold)).monospacedDigit()
        .accessibilityIdentifier("usage-total")
      Text(state.sessions.count == 1 ? "1 session" : "\(state.sessions.count) sessions")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(Theme.Spacing.large)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(cornerRadius: Theme.Radius.medium)
  }

  private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var dailyChart: some View {
    if state.daily.isEmpty {
      empty("No spend recorded in this range")
    } else {
      UsageDailyChart(daily: state.daily, formatCost: actions.formatCost)
        .frame(height: 200)
    }
  }

  @ViewBuilder private func breakdown(_ amounts: [UsageAmount]) -> some View {
    if amounts.isEmpty {
      empty("No data")
    } else {
      // Every entry, as the web's chart grows with its data, so the bars add up to the total.
      Chart(amounts) { amount in
        BarMark(x: .value("Cost", amount.costUSD), y: .value("Name", amount.label))
          .foregroundStyle(Theme.accent)
          .annotation(position: .trailing) {
            Text(actions.formatCost(amount.costUSD)).font(.caption2).foregroundStyle(.secondary)
          }
      }
      .chartXAxis(.hidden)
      .frame(height: CGFloat(amounts.count) * 28 + 16)
    }
  }

  @ViewBuilder private var sessions: some View {
    if state.sessions.isEmpty {
      empty("No sessions in this range")
    } else if isCompact {
      // A table shows only its first column at iPhone width.
      UsageSessionList(
        sessions: state.sessions.sorted(using: sortOrder), sortOrder: $sortOrder,
        openSession: actions.openSession)
    } else {
      Table(state.sessions.sorted(using: sortOrder), sortOrder: $sortOrder) {
        TableColumn("Session", value: \.title) { row in
          Button(row.title) { actions.openSession?(row.id) }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(actions.openSession == nil)
        }
        TableColumn("Model", value: \.model)
        TableColumn("Harness", value: \.harness)
        TableColumn("Last active", value: \.updatedAt) { row in
          Text(row.updatedAt, format: .relative(presentation: .named))
        }
        TableColumn("Cost", value: \.costUSD) { row in
          Text(row.costText).monospacedDigit()
        }
        .width(min: 60, ideal: 80)
      }
      .frame(minHeight: 240, idealHeight: CGFloat(state.sessions.count) * 28 + 40)
      .accessibilityIdentifier("usage-sessions")
    }
  }

  private func empty(_ text: String) -> some View {
    Text(text).font(.callout).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: 80)
      .cardSurface(cornerRadius: Theme.Radius.medium)
  }
}
