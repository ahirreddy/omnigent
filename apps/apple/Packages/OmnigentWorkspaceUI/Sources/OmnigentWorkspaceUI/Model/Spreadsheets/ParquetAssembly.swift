/// One leaf column's levels and values, as its pages decoded them.
nonisolated struct ParquetLeafData {
  var definitions: [Int] = []
  var repetitions: [Int] = []
  var values: [ParquetValue] = []
}

/// Builds rows of nested values from leaf columns' levels, as hyparquet's `assembleLists` and
/// `assembleNested` do: lists from repetition levels, nulls from definition levels, then
/// structs, lists and maps from the schema.
nonisolated enum ParquetAssembly {
  /// A leaf's values per row, nested in a list for each non-required level of its path.
  /// - Parameters:
  ///   - data: The leaf's levels and values.
  ///   - path: The repetition of each node from the schema's root (required) to the leaf.
  /// - Returns: One value per row.
  /// - Throws: ``ParquetMalformed`` when the levels and values don't agree.
  static func lists(_ data: ParquetLeafData, path: [ParquetRepetition]) throws(ParquetMalformed)
    -> [ParquetValue]
  {
    let maxDefinition = path.dropFirst().count(where: { $0 != .required })
    let count = max(data.definitions.count, data.repetitions.count)
    guard count > 0 else { return data.values }
    var lists = OpenLists(path: path)
    var valueIndex = 0
    for index in 0..<count {
      let definition =
        data.definitions.indices.contains(index) ? data.definitions[index] : maxDefinition
      lists.close(
        repeatingAt: data.repetitions.indices.contains(index) ? data.repetitions[index] : 0)
      lists.open(definedTo: definition)
      if definition == maxDefinition {
        guard data.values.indices.contains(valueIndex) else { throw ParquetMalformed() }
        lists.append(data.values[valueIndex])
        valueIndex += 1
      } else {
        lists.append(lists.depth == path.count - 2 ? .null : .list([]))
      }
    }
    return lists.rows()
  }

  /// Replaces the leaf columns under `node` in `data` with `node`'s own values.
  /// - Parameters:
  ///   - data: Values per row, by node key.
  ///   - node: The schema node.
  ///   - depth: How many lists deep `node`'s values sit in each row.
  /// - Throws: ``ParquetMalformed`` when a child's values are missing or don't line up.
  static func nested(_ data: inout [String: [ParquetValue]], _ node: ParquetSchemaNode, depth: Int)
    throws(ParquetMalformed)
  {
    let optional = node.repetition == .optional
    let nextDepth = optional ? depth + 1 : depth
    if node.isListLike {
      var element = node.children[0]
      var elementDepth = nextDepth
      if element.children.count == 1 {
        element = element.children[0]
        elementDepth += 1
      }
      try nested(&data, element, depth: elementDepth)
      guard let values = data.removeValue(forKey: element.key) else { throw ParquetMalformed() }
      data[node.key] = optional ? flatten(values, depth: depth) : values
    } else if node.isMapLike {
      let entries = node.children[0]
      for child in entries.children { try nested(&data, child, depth: nextDepth + 1) }
      let keyNode = entries.children.first { $0.name == "key" } ?? entries.children[0]
      let valueNode = entries.children.first { $0.name == "value" } ?? entries.children[1]
      guard let keys = data.removeValue(forKey: keyNode.key),
        let values = data.removeValue(forKey: valueNode.key), keys.count == values.count
      else { throw ParquetMalformed() }
      let maps = try self.maps(keys, values, depth: nextDepth)
      data[node.key] = optional ? flatten(maps, depth: depth) : maps
    } else if !node.children.isEmpty {
      let invertDepth = node.repetition == .required ? depth : depth + 1
      var members: [(String, [ParquetValue])] = []
      for child in node.children {
        try nested(&data, child, depth: invertDepth)
        guard let values = data.removeValue(forKey: child.key) else { throw ParquetMalformed() }
        members.append((child.name, values))
      }
      let structs = try invert(members, depth: invertDepth)
      data[node.key] = optional ? flatten(structs, depth: depth) : structs
    }
  }

  /// Each value at `depth` replaced by the first item of its list (an optional level's list).
  private static func flatten(_ values: [ParquetValue], depth: Int) -> [ParquetValue] {
    values.map { value in
      guard case .list(let items) = value else { return depth > 0 ? value : .missing }
      return depth > 0 ? .list(flatten(items, depth: depth - 1)) : items.first ?? .missing
    }
  }

  /// Key and value lists paired into objects at `depth`.
  private static func maps(_ keys: [ParquetValue], _ values: [ParquetValue], depth: Int)
    throws(ParquetMalformed) -> [ParquetValue]
  {
    try zip(keys, values).map { (pair) throws(ParquetMalformed) -> ParquetValue in
      let keyItems = items(pair.0)
      let valueItems = items(pair.1)
      if depth > 0 { return .list(try maps(keyItems, valueItems, depth: depth - 1)) }
      guard case .list = pair.0 else { return .missing }
      return .object(
        keyItems.enumerated().map { index, name in
          // A key without its value maps to null.
          var item = valueItems.indices.contains(index) ? valueItems[index] : .null
          if case .missing = item { item = .null }
          return ParquetField(name: ParquetText.cell(name, isDate: false), value: item)
        })
    }
  }

  /// Members' values zipped into structs at `depth`.
  private static func invert(_ members: [(String, [ParquetValue])], depth: Int)
    throws(ParquetMalformed) -> [ParquetValue]
  {
    let length = members.first?.1.count ?? 0
    guard members.allSatisfy({ $0.1.count == length }) else { throw ParquetMalformed() }
    return try (0..<length).map { (index: Int) throws(ParquetMalformed) -> ParquetValue in
      if depth > 0 {
        return .list(try invert(members.map { ($0.0, items($0.1[index])) }, depth: depth - 1))
      }
      return .object(members.map { ParquetField(name: $0.0, value: $0.1[index]) })
    }
  }

  private static func items(_ value: ParquetValue) -> [ParquetValue] {
    if case .list(let items) = value { items } else { [] }
  }
}

/// The lists open while a leaf's levels are read, the innermost last (hyparquet's container
/// stack), with the schema depth and the definition and repetition levels reached.
nonisolated private struct OpenLists {
  let path: [ParquetRepetition]
  private var stack: [[ParquetValue]] = [[]]
  private(set) var depth = 0
  private var definitionLevel = 0
  private var repetitionLevel = 0

  init(path: [ParquetRepetition]) {
    self.path = path
  }

  private func repetition(_ index: Int) -> ParquetRepetition? {
    path.indices.contains(index) ? path[index] : nil
  }

  /// Closes the lists past the level a value repeats at.
  mutating func close(repeatingAt level: Int) {
    while depth > 0, level < repetitionLevel || repetition(depth) != .repeated {
      if repetition(depth) != .required {
        closeInnermost()
        definitionLevel -= 1
      }
      if repetition(depth) == .repeated { repetitionLevel -= 1 }
      depth -= 1
    }
  }

  /// Opens lists down to where a value is defined.
  mutating func open(definedTo definition: Int) {
    while depth < path.count - 2 || repetition(depth + 1) == .repeated,
      definitionLevel < definition || repetition(depth + 1) == .required
    {
      depth += 1
      if repetition(depth) != .required {
        stack.append([])
        definitionLevel += 1
      }
      if repetition(depth) == .repeated { repetitionLevel += 1 }
    }
  }

  mutating func append(_ value: ParquetValue) {
    stack[stack.count - 1].append(value)
  }

  /// One value per row, every list closed.
  mutating func rows() -> [ParquetValue] {
    while stack.count > 1 { closeInnermost() }
    return stack[0]
  }

  private mutating func closeInnermost() {
    let finished = stack.removeLast()
    stack[stack.count - 1].append(.list(finished))
  }
}
