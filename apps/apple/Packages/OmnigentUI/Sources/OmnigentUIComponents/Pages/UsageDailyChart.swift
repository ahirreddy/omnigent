import Charts
import SwiftUI

/// Daily cost on a date axis, as the web's `CostTimelineChart`: days without spend stay empty,
/// and hovering a day shows its date and cost.
struct UsageDailyChart: View {
  let daily: [UsageAmount]
  let formatCost: (Double) -> String
  @State private var selected: Date?

  private struct Day: Identifiable {
    let date: Date
    let cost: Double
    var id: Date { date }
  }

  private var days: [Day] {
    daily.compactMap { amount in amount.day().map { Day(date: $0, cost: amount.costUSD) } }
  }

  private var selectedDay: Day? {
    guard let selected else { return nil }
    let calendar = Calendar.current
    return days.first { calendar.isDate($0.date, inSameDayAs: selected) }
  }

  var body: some View {
    Chart {
      ForEach(days) { day in
        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Cost", day.cost))
          .foregroundStyle(
            Theme.accent.opacity(selectedDay == nil || selectedDay?.id == day.id ? 1 : 0.5))
      }
      if let day = selectedDay {
        RuleMark(x: .value("Day", day.date, unit: .day))
          .foregroundStyle(.clear)
          .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
            VStack(alignment: .leading, spacing: 2) {
              Text(day.date, format: .dateTime.month(.abbreviated).day())
                .foregroundStyle(.secondary)
              Text(formatCost(day.cost)).monospacedDigit().fontWeight(.medium)
            }
            .font(.callout)
            .padding(.horizontal, Theme.Spacing.small).padding(.vertical, Theme.Spacing.tiny)
            .cardSurface(cornerRadius: Theme.Radius.small)
          }
      }
    }
    .chartXSelection(value: $selected)
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 6)) { _ in
        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
      }
    }
    .chartYAxis {
      AxisMarks { value in
        AxisGridLine()
        AxisValueLabel { Text(formatCost(value.as(Double.self) ?? 0)) }
      }
    }
    .accessibilityIdentifier("usage-daily-chart")
  }
}
