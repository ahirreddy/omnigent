nonisolated extension ParquetPageReader {
  // A data page's present values in `encoding`.
  // swiftlint:disable:next cyclomatic_complexity
  func decodeValues(
    _ bytes: ArraySlice<UInt8>, encoding: Int64, count: Int, dictionary: [ParquetValue]
  ) throws(ParquetPageFailure) -> [ParquetValue] {
    let converter = column.converter
    var cursor = ParquetCursor(bytes)
    do {
      switch encoding {
      case 0:
        return try plain(&cursor, count: count)
      case 2, 8:
        return try dictionaryValues(bytes, count: count, dictionary: dictionary)
      case 3 where converter.type == .boolean:
        let length = Int(try cursor.number(bytes: 4))
        return try ParquetEncodings.hybrid(try cursor.take(length), bitWidth: 1, count: count)
          .map { converter.value($0 == 1) }
      case 5:
        let integers = try ParquetEncodings.deltaBinaryPacked(&cursor)
        guard integers.count >= count else { throw ParquetMalformed() }
        return integers.prefix(count).map {
          converter.type == .int32
            ? converter.value(Int32(truncatingIfNeeded: $0)) : converter.value($0)
        }
      case 6:
        return try ParquetEncodings.deltaLengthByteArray(&cursor).prefix(count).map {
          converter.value($0)
        }
      case 7:
        return try ParquetEncodings.deltaByteArray(&cursor).prefix(count).map {
          converter.value($0)
        }
      case 9:
        return try streamSplit(bytes, count: count)
      default:
        let name =
          Self.encodingNames.indices.contains(Int(encoding))
          ? Self.encodingNames[Int(encoding)] : "encoding \(encoding)"
        throw ParquetPageFailure.unsupportedEncoding(name)
      }
    } catch let failure as ParquetPageFailure {
      throw failure
    } catch {
      throw .malformed
    }
  }

  private func dictionaryValues(_ bytes: ArraySlice<UInt8>, count: Int, dictionary: [ParquetValue])
    throws(ParquetMalformed) -> [ParquetValue]
  {
    guard count > 0 else { return [] }
    guard let width = bytes.first else { throw ParquetMalformed() }
    let indices = try ParquetEncodings.hybrid(bytes.dropFirst(), bitWidth: Int(width), count: count)
    return try indices.map { (index: Int) throws(ParquetMalformed) -> ParquetValue in
      guard dictionary.indices.contains(index) else { throw ParquetMalformed() }
      return dictionary[index]
    }
  }

  /// `BYTE_STREAM_SPLIT` values, each reassembled and read as `PLAIN`.
  private func streamSplit(_ bytes: ArraySlice<UInt8>, count: Int) throws(ParquetPageFailure)
    -> [ParquetValue]
  {
    let width: Int =
      switch column.converter.type {
      case .int32, .float: 4
      case .int64, .double: 8
      case .fixedLengthByteArray: column.node.typeLength
      default: 0
      }
    do {
      let values = try ParquetEncodings.byteStreamSplit(bytes, width: width, count: count)
      var cursor = ParquetCursor(ArraySlice(values.flatMap(\.self)))
      return try plain(&cursor, count: count)
    } catch {
      throw .malformed
    }
  }

  /// `count` `PLAIN` values of the column's type.
  func plain(_ cursor: inout ParquetCursor, count: Int) throws(ParquetPageFailure)
    -> [ParquetValue]
  {
    let converter = column.converter
    // Every value takes at least a byte (a bit for booleans), so a count past them is malformed.
    let smallest = converter.type == .boolean ? 0 : 1
    guard count >= 0, count * smallest <= cursor.remaining else { throw .malformed }
    var values: [ParquetValue] = []
    values.reserveCapacity(count)
    do {
      if converter.type == .boolean {
        let bits = try cursor.take((count + 7) / 8)
        return ParquetEncodings.unpack(bits, bitWidth: 1, count: count).map {
          converter.value($0 == 1)
        }
      }
      for _ in 0..<count { values.append(try plainValue(&cursor, converter: converter)) }
    } catch {
      throw .malformed
    }
    return values
  }

  private func plainValue(_ cursor: inout ParquetCursor, converter: ParquetConverter)
    throws(ParquetMalformed) -> ParquetValue
  {
    switch converter.type {
    case .boolean:
      return converter.value((try cursor.take(1).first ?? 0) & 1 == 1)
    case .int32:
      return converter.value(Int32(truncatingIfNeeded: try cursor.number(bytes: 4)))
    case .int64:
      return converter.value(Int64(bitPattern: try cursor.number(bytes: 8)))
    case .int96:
      return converter.value(try cursor.take(12))
    case .float:
      return converter.value(Float(bitPattern: UInt32(try cursor.number(bytes: 4))))
    case .double:
      return converter.value(Double(bitPattern: try cursor.number(bytes: 8)))
    case .byteArray:
      return converter.value(try cursor.take(Int(try cursor.number(bytes: 4))))
    case .fixedLengthByteArray:
      return converter.value(try cursor.take(converter.typeLength))
    }
  }
}
