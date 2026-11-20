/// A field's repetition in a Parquet schema.
nonisolated enum ParquetRepetition {
  case required
  case optional
  case repeated
}

/// A Parquet column's physical type.
nonisolated enum ParquetPhysicalType: Int64 {
  case boolean = 0
  case int32 = 1
  case int64 = 2
  case int96 = 3
  case float = 4
  case double = 5
  case byteArray = 6
  case fixedLengthByteArray = 7
}

/// What a column's values mean beyond their physical type: Parquet's converted and logical types
/// folded into what the preview shows differently.
nonisolated enum ParquetMeaning: Hashable {
  case plain
  case string
  case date
  /// A timestamp whose integers count this many units per millisecond.
  case timestamp(perMillisecond: Int64)
  case decimal(scale: Int)
  case unsigned
  case uuid
  case float16
  case list
  case map
}

/// One schema element and its children: a top-level field, a group inside one, or a leaf column.
nonisolated struct ParquetSchemaNode {
  let name: String
  let repetition: ParquetRepetition
  let physicalType: ParquetPhysicalType?
  let typeLength: Int
  let meaning: ParquetMeaning
  var children: [Self] = []
  /// The names from the top-level field down to this one.
  var path: [String] = []

  /// The node's place among the decoded columns.
  var key: String { path.joined(separator: "\u{1F}") }

  /// A `LIST`-annotated group of one repeated group (web `isListLike`).
  var isListLike: Bool {
    meaning == .list && children.count == 1 && children[0].children.count <= 1
      && children[0].repetition == .repeated
  }

  /// A `MAP`-annotated group of one repeated key and value group (web `isMapLike`).
  var isMapLike: Bool {
    guard meaning == .map, children.count == 1, children[0].repetition == .repeated,
      children[0].children.count == 2
    else { return false }
    return children[0].children.allSatisfy { $0.repetition != .repeated }
  }

  /// The leaf columns under this node, in schema order, each with the nodes leading to it.
  func leaves(from ancestors: [Self] = []) -> [[Self]] {
    let chain = ancestors + [self]
    return children.isEmpty ? [chain] : children.flatMap { $0.leaves(from: chain) }
  }
}

/// One column chunk's metadata.
nonisolated struct ParquetColumnChunk {
  let path: [String]
  let codec: Int64
  let valueCount: Int64
  let uncompressedSize: Int64
  let compressedSize: Int64
  /// Where its first page (a dictionary page when it has one) starts.
  let start: Int64
  /// The data is in another file.
  let external: Bool
}

/// One row group: its rows and its chunks, in schema leaf order.
nonisolated struct ParquetRowGroup {
  let rowCount: Int64
  let columns: [ParquetColumnChunk]
}

/// A Parquet file's footer.
nonisolated struct ParquetMetadata {
  let rowCount: Int64
  let rowGroups: [ParquetRowGroup]
  /// The top-level fields.
  let fields: [ParquetSchemaNode]

  static let codecNames = [
    "UNCOMPRESSED", "SNAPPY", "GZIP", "LZO", "BROTLI", "LZ4", "ZSTD", "LZ4_RAW",
  ]

  /// The footer decoded from its Thrift struct.
  /// - Parameter file: `FileMetaData`.
  /// - Throws: ``ThriftMalformed`` for a schema that doesn't nest as it says.
  init(_ file: ThriftStruct) throws(ThriftMalformed) {
    rowCount = file.int(3) ?? 0
    let elements = file.structures(2)
    guard let root = elements.first else { throw ThriftMalformed() }
    var index = 1
    var fields: [ParquetSchemaNode] = []
    let fieldCount = Int(root.int(5) ?? 0)
    guard fieldCount >= 0 else { throw ThriftMalformed() }
    for _ in 0..<fieldCount {
      fields.append(try Self.node(elements, at: &index, path: []))
    }
    self.fields = fields
    rowGroups = file.structures(4).map { group in
      ParquetRowGroup(
        rowCount: group.int(3) ?? 0,
        columns: group.structures(1).map(Self.chunk))
    }
  }

  private static func node(_ elements: [ThriftStruct], at index: inout Int, path: [String])
    throws(ThriftMalformed) -> ParquetSchemaNode
  {
    guard index < elements.count else { throw ThriftMalformed() }
    let element = elements[index]
    index += 1
    let name = element.string(4) ?? ""
    var node = ParquetSchemaNode(
      name: name,
      repetition: repetition(element.int(3)),
      physicalType: element.int(1).flatMap(ParquetPhysicalType.init(rawValue:)),
      typeLength: Int(element.int(2) ?? 0),
      meaning: meaning(element))
    node.path = path + [name]
    let childCount = Int(element.int(5) ?? 0)
    // Every child is a later element, so more children than elements left is malformed.
    guard childCount >= 0, childCount <= elements.count - index else { throw ThriftMalformed() }
    for _ in 0..<childCount {
      node.children.append(try Self.node(elements, at: &index, path: node.path))
    }
    return node
  }

  private static func repetition(_ value: Int64?) -> ParquetRepetition {
    switch value ?? 0 {
    case 1: .optional
    case 2: .repeated
    default: .required
    }
  }

  private static func chunk(_ chunk: ThriftStruct) -> ParquetColumnChunk {
    let meta = chunk.structure(3) ?? ThriftStruct()
    let dictionary = meta.int(11) ?? 0
    return ParquetColumnChunk(
      path: meta.list(3).compactMap {
        if case .binary(let bytes) = $0 { SpreadsheetText.utf8(bytes) } else { nil }
      },
      codec: meta.int(4) ?? -1, valueCount: meta.int(5) ?? -1,
      uncompressedSize: meta.int(6) ?? -1, compressedSize: meta.int(7) ?? -1,
      start: dictionary > 0 ? dictionary : meta.int(9) ?? -1,
      external: chunk.string(1) != nil)
  }

  /// What a schema element's values mean, from its logical type, else its converted type.
  private static func meaning(_ element: ThriftStruct) -> ParquetMeaning {
    if let logical = element.structure(10), let meaning = logicalMeaning(logical) {
      return meaning
    }
    let scale = Int(element.int(7) ?? 0)
    switch element.int(6) ?? -1 {
    case 0, 4, 19: return .string  // UTF8, ENUM, JSON
    case 1, 2: return .map  // MAP, MAP_KEY_VALUE
    case 3: return .list
    case 5: return .decimal(scale: scale)
    case 6: return .date
    case 9: return .timestamp(perMillisecond: 1)
    case 10: return .timestamp(perMillisecond: 1000)
    case 11, 12, 13, 14: return .unsigned  // UINT_8 to UINT_64
    default: return .plain
    }
  }

  private static func logicalMeaning(_ logical: ThriftStruct) -> ParquetMeaning? {
    switch logical.unionField ?? -1 {
    case 1, 4, 12: return .string  // STRING, ENUM, JSON
    case 2: return .map
    case 3: return .list
    case 5: return .decimal(scale: Int(logical.structure(5)?.int(1) ?? 0))
    case 6: return .date
    case 8:
      let unit = logical.structure(8)?.structure(2)?.unionField
      return .timestamp(perMillisecond: unit == 3 ? 1_000_000 : unit == 2 ? 1000 : 1)
    case 10:
      return logical.structure(10)?.flag(2, default: true) == false ? .unsigned : .plain
    case 14: return .uuid
    case 15: return .float16
    default: return nil
    }
  }
}
