import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Usage sessions on iPhone")
struct UsageSessionSortTests {
  private func row(_ id: String, cost: Double, updated: TimeInterval) -> UsageSessionRow {
    UsageSessionRow(
      id: id, title: id, model: "m", harness: "h",
      updatedAt: Date(timeIntervalSince1970: updated), costUSD: cost, costText: "$\(cost)")
  }

  @Test("each sort round-trips through the table order it sets")
  func roundTrip() {
    for sort in UsageSessionSort.allCases {
      #expect(UsageSessionSort(sort.order) == sort)
    }
    #expect(UsageSessionSort([]) == .recent)
  }

  @Test("a column the wide table flipped still reads as that column")
  func flippedColumn() {
    #expect(UsageSessionSort([KeyPathComparator(\UsageSessionRow.costUSD)]) == .cost)
    #expect(
      UsageSessionSort([KeyPathComparator(\UsageSessionRow.title, order: .reverse)]) == .title)
    #expect(UsageSessionSort([KeyPathComparator(\UsageSessionRow.model)]) == .recent)
  }

  @Test("the orders put the newest, costliest, or first title on top")
  func orders() {
    let rows = [
      row("b", cost: 1, updated: 30), row("a", cost: 3, updated: 10),
      row("c", cost: 2, updated: 20),
    ]
    #expect(rows.sorted(using: UsageSessionSort.recent.order).map(\.id) == ["b", "c", "a"])
    #expect(rows.sorted(using: UsageSessionSort.cost.order).map(\.id) == ["a", "c", "b"])
    #expect(rows.sorted(using: UsageSessionSort.title.order).map(\.id) == ["a", "b", "c"])
  }
}
