import Charts
import SwiftUI

/// An agent-posted item, opened: its body, charts, links, where it came from, Dismiss with a
/// reason and the agent's actions, as the web's suggestion card.
struct InboxSuggestionDetail: View {
  let item: InboxItem
  let suggestion: InboxSuggestion
  let actions: InboxActions

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      Text(suggestion.title).font(Theme.Typography.label).fontWeight(.semibold)
      MarkdownView(suggestion.body)
        .frame(maxWidth: .infinity, alignment: .leading)
      ForEach(suggestion.charts) { InboxChartView(chart: $0) }
      if !suggestion.links.isEmpty { links }
      postedFrom
      buttons
    }
    .accessibilityIdentifier("inbox-suggestion-\(item.id)")
  }

  private var links: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      Text("Source").font(.caption.weight(.medium)).foregroundStyle(.secondary)
      ForEach(suggestion.links) { link in
        Button(link.title) { actions.openLink?(link) }
          #if os(macOS)
            .buttonStyle(.link)
          #else
            .buttonStyle(.borderless)
          #endif
          .lineLimit(1)
          .disabled(actions.openLink == nil)
          .accessibilityIdentifier("inbox-suggestion-link-\(link.id)")
      }
    }
    .font(.callout)
  }

  private var postedFrom: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      Text("Posted from").foregroundStyle(.secondary)
      Button(suggestion.sourceTitle) { actions.openSource?(item) }
        #if os(macOS)
          .buttonStyle(.link)
        #else
          .buttonStyle(.borderless)
        #endif
        .disabled(actions.openSource == nil)
        .accessibilityIdentifier("inbox-suggestion-source-\(item.id)")
      if !item.agentName.isEmpty, item.agentName != suggestion.sourceTitle {
        Text("\u{00B7} \(item.agentName)").foregroundStyle(.secondary)
      }
    }
    .font(.callout)
  }

  private var buttons: some View {
    HStack {
      Spacer(minLength: 0)
      if let dismiss = actions.dismissSuggestion {
        Menu("Dismiss") {
          ForEach(suggestion.dismissChoices) { choice in
            Button(choice.title) { dismiss(item, choice) }
          }
        }
        .fixedSize()
        .accessibilityIdentifier("inbox-suggestion-dismiss-\(item.id)")
      }
      if let take = actions.takeSuggestionAction {
        ForEach(Array(suggestion.actions.enumerated()), id: \.offset) { index, label in
          if index == 0 {
            Button(label) { take(item, index) }.primaryActionStyle()
              .accessibilityIdentifier("inbox-suggestion-action-\(item.id)-\(index)")
          } else {
            Button(label) { take(item, index) }.buttonStyle(.bordered)
              .accessibilityIdentifier("inbox-suggestion-action-\(item.id)-\(index)")
          }
        }
      }
    }
  }
}

/// A failed automation, opened: its name and why, Open automation and Mark as read.
struct InboxAutomationFailureDetail: View {
  let item: InboxItem
  let failure: InboxAutomationFailure
  let actions: InboxActions

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text(failure.name).font(Theme.Typography.label).fontWeight(.semibold)
      Text(failure.reason).font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        if let open = actions.openAutomation {
          Button("Open automation", systemImage: "arrow.up.forward.app") { open(item) }
            .primaryActionStyle()
            .accessibilityIdentifier("inbox-open-automation-\(item.id)")
        }
        if let markRead = actions.markRead {
          Button("Mark as read", systemImage: "envelope.open") { markRead(item) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("inbox-mark-read-\(item.id)")
        }
      }
    }
    .accessibilityIdentifier("inbox-automation-failure-\(item.id)")
  }
}

/// An agent's chart: lines or bars with an optional band, markers and source.
struct InboxChartView: View {
  let chart: InboxChart

  private struct Point: Identifiable {
    let series: String
    let index: Int
    let label: String
    let value: Double
    let emphasis: Bool
    var id: String { "\(series)-\(index)" }
  }

  private var points: [Point] {
    chart.series.flatMap { series in
      series.values.enumerated().compactMap { index, value in
        value.map {
          Point(
            series: series.name, index: index, label: chart.labels[index], value: $0,
            emphasis: series.emphasis)
        }
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text(chart.title).font(.callout.weight(.medium))
      Chart {
        if let band = chart.highlight {
          RectangleMark(
            xStart: .value("From", chart.labels[band.lowerBound]),
            xEnd: .value("To", chart.labels[band.upperBound])
          )
          .foregroundStyle(Theme.accent.opacity(0.12))
        }
        ForEach(points) { point in
          if chart.isBar {
            BarMark(x: .value("Label", point.label), y: .value("Value", point.value))
              .foregroundStyle(by: .value("Series", point.series))
              .opacity(point.emphasis || chart.series.count == 1 ? 1 : 0.6)
          } else {
            LineMark(x: .value("Label", point.label), y: .value("Value", point.value))
              .foregroundStyle(by: .value("Series", point.series))
              .interpolationMethod(.monotone)
              .lineStyle(StrokeStyle(lineWidth: point.emphasis ? 3 : 1.5))
          }
        }
        ForEach(chart.markers.sorted { $0.key < $1.key }, id: \.key) { index, label in
          RuleMark(x: .value("Marker", chart.labels[index]))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(.secondary)
            .annotation(position: .top) { Text(label).font(.caption2).foregroundStyle(.secondary) }
        }
      }
      .chartXScale(domain: chart.labels)
      .chartLegend(chart.series.count > 1 ? .visible : .hidden)
      .chartYAxis {
        AxisMarks { value in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
          AxisValueLabel { Text(Self.format(value.as(Double.self) ?? 0, unit: chart.unit)) }
        }
      }
      .frame(height: 192)
      if let source = chart.source {
        if let url = chart.sourceURL {
          Link("Source: \(source)", destination: url).font(.caption)
        } else {
          Text("Source: \(source)").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(chart.title)
    .accessibilityIdentifier("inbox-chart")
  }

  /// A value with the chart's unit, as the web: `12 ms`, `40%`, `1.25`, at most two decimals.
  static func format(_ value: Double, unit: String?) -> String {
    let text: String
    if value.rounded() == value, abs(value) < 1e15 {
      text = String(Int64(value))
    } else {
      let hundredths = (value * 100).rounded() / 100
      text =
        hundredths.rounded() == hundredths && abs(hundredths) < 1e15
        ? String(Int64(hundredths)) : "\(hundredths)"
    }
    guard let unit, !unit.isEmpty else { return text }
    return unit == "%" ? "\(text)%" : "\(text) \(unit)"
  }
}
