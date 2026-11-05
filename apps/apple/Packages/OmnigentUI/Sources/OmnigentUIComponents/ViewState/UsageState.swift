public import Foundation

/// The Usage page's date range.
nonisolated public enum UsageRange: String, Hashable, Sendable, CaseIterable, Identifiable {
  /// The last 7 days.
  case week
  /// The last 30 days.
  case month
  /// The last 90 days.
  case quarter
  /// Everything.
  case all
  /// Chosen days.
  case custom

  /// The range itself.
  public var id: Self { self }

  /// The label.
  public var title: String {
    switch self {
    case .week: "7 days"
    case .month: "30 days"
    case .quarter: "90 days"
    case .all: "All time"
    case .custom: "Custom"
    }
  }

  /// The preset's length in days; `nil` for all time and custom.
  public var days: Int? {
    switch self {
    case .week: 7
    case .month: 30
    case .quarter: 90
    case .all, .custom: nil
    }
  }
}

/// A labelled amount for the Usage charts.
nonisolated public struct UsageAmount: Hashable, Sendable, Identifiable {
  /// The day (`YYYY-MM-DD`), harness or model.
  public var label: String
  /// US dollars.
  public var costUSD: Double

  /// The label.
  public var id: String { label }

  /// Creates an amount.
  public init(label: String, costUSD: Double) {
    self.label = label
    self.costUSD = costUSD
  }

  /// A daily amount's day, as the start of that calendar day in `calendar`, so the chart's date
  /// axis labels it as the same day; `nil` for a label that is not `YYYY-MM-DD`.
  func day(in calendar: Calendar = .current) -> Date? {
    let parts = label.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, label.count == 10 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }
}

/// One session in the Usage table.
nonisolated public struct UsageSessionRow: Hashable, Sendable, Identifiable {
  /// Session id.
  public var id: String
  /// Title.
  public var title: String
  /// The costliest model, and how many others.
  public var model: String
  /// Harness, or an em dash.
  public var harness: String
  /// Last activity.
  public var updatedAt: Date
  /// US dollars.
  public var costUSD: Double
  /// `$1.23`.
  public var costText: String

  /// Creates a row.
  public init(
    id: String, title: String, model: String, harness: String, updatedAt: Date, costUSD: Double,
    costText: String
  ) {
    self.id = id
    self.title = title
    self.model = model
    self.harness = harness
    self.updatedAt = updatedAt
    self.costUSD = costUSD
    self.costText = costText
  }
}

/// The Usage page.
nonisolated public struct UsageViewState: Hashable, Sendable {
  /// The window's total, `$12.34`.
  public var totalText: String
  /// Spend per day.
  public var daily: [UsageAmount]
  /// Cost by harness.
  public var byHarness: [UsageAmount]
  /// Cost by model.
  public var byModel: [UsageAmount]
  /// Sessions in the window.
  public var sessions: [UsageSessionRow]
  /// The first read is in flight.
  public var isLoading: Bool
  /// Why the report could not be read.
  public var loadError: String?

  /// Creates the state.
  public init(
    totalText: String = "$0.00", daily: [UsageAmount] = [], byHarness: [UsageAmount] = [],
    byModel: [UsageAmount] = [], sessions: [UsageSessionRow] = [], isLoading: Bool = false,
    loadError: String? = nil
  ) {
    self.totalText = totalText
    self.daily = daily
    self.byHarness = byHarness
    self.byModel = byModel
    self.sessions = sessions
    self.isLoading = isLoading
    self.loadError = loadError
  }
}

/// What the Usage page can do.
public struct UsageActions {
  /// Change the window: a preset, or the custom start and end days.
  public var setRange: (@MainActor (UsageRange, Date, Date) -> Void)?
  /// Open a session.
  public var openSession: (@MainActor (String) -> Void)?
  /// Read the report again.
  public var retry: (@MainActor () -> Void)?
  /// Format a cost, `$1.23`.
  public var formatCost: @MainActor (Double) -> String

  /// Creates actions.
  public init(formatCost: @escaping @MainActor (Double) -> String) {
    self.formatCost = formatCost
  }
}
