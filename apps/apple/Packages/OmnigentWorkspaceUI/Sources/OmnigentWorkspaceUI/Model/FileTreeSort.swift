import Foundation

/// How the Files tab orders entries, as the web's sort menu: folders first, then by the chosen
/// key, with the path breaking ties.
nonisolated public enum FileTreeSort: String, CaseIterable, Identifiable, Sendable {
  /// By name.
  case name
  /// Most recently edited first; entries without a time last.
  case lastEdited
  /// Largest first; folders and entries without a size by name.
  case size
  /// By extension.
  case type

  /// The raw value.
  public var id: String { rawValue }

  /// The menu title.
  public var title: String {
    switch self {
    case .name: "Filename"
    case .lastEdited: "Last edited"
    case .size: "Size"
    case .type: "Type"
    }
  }

  /// The menu symbol.
  public var symbol: String {
    switch self {
    case .name: "textformat"
    case .lastEdited: "clock"
    case .size: "arrow.up.arrow.down"
    case .type: "doc"
    }
  }

  /// `entries` in this order.
  /// - Parameter entries: Siblings, or search matches.
  /// - Returns: The ordered entries.
  public func sorted(_ entries: [WorkspaceEntry]) -> [WorkspaceEntry] {
    entries.sorted { left, right in
      let leftIsFolder = left.kind.isDirectory
      if leftIsFolder != right.kind.isDirectory { return leftIsFolder }
      return ascends(left, right)
    }
  }

  private func ascends(_ left: WorkspaceEntry, _ right: WorkspaceEntry) -> Bool {
    let byPath = left.path.localizedStandardCompare(right.path) == .orderedAscending
    switch self {
    case .name:
      return byPath
    case .lastEdited:
      return Self.descending(left.modifiedAt, right.modifiedAt, otherwise: byPath)
    case .size:
      return Self.descending(left.size, right.size, otherwise: byPath)
    case .type:
      let leftType = Self.fileExtension(left.name)
      let rightType = Self.fileExtension(right.name)
      return leftType == rightType ? byPath : leftType < rightType
    }
  }

  /// Larger first and missing values last; `tie` when the values do not decide.
  private static func descending<Value: Comparable>(
    _ left: Value?, _ right: Value?, otherwise tie: Bool
  ) -> Bool {
    switch (left, right) {
    case (nil, nil): tie
    case (nil, _): false
    case (_, nil): true
    case (let left?, let right?): left == right ? tie : left > right
    }
  }

  private static func fileExtension(_ name: String) -> String {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
    return name[name.index(after: dot)...].lowercased()
  }
}
