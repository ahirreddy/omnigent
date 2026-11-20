import Foundation
import SwiftUI

/// A tool call's input or result as the web's Fields view shows it: a JSON object's keys
/// beside their values, short text inline, anything else as code.
nonisolated enum ToolFieldValue: Hashable, Sendable {
  /// Text, a number or a flag, as written.
  case scalar(String)
  /// `null`.
  case empty
  /// An object's fields, in order.
  case fields([ToolField])
  /// Anything else (a list, a deep object), as two-space JSON.
  case code(String)

  /// The longest JSON the fields show; longer output stays code, as the web's preview limit.
  static let fieldLimit = 4_000

  /// `text` as fields when it is a JSON object that fits, else none.
  static func fields(json text: String) -> [ToolField] {
    guard text.count <= fieldLimit, let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
      case .fields(let fields) = value(object, depth: 0)
    else { return [] }
    return fields
  }

  static func value(_ object: Any, depth: Int) -> Self {
    switch object {
    case is NSNull: return .empty
    case let text as String: return .scalar(text)
    // swiftlint:disable:next legacy_objc_type
    case let number as NSNumber:
      let isFlag = CFGetTypeID(number) == CFBooleanGetTypeID()
      return .scalar(isFlag ? (number.boolValue ? "true" : "false") : number.stringValue)
    case let dictionary as [String: Any] where depth < 2:
      // JSONSerialization drops key order; sorted keys read the same every time.
      return .fields(
        dictionary.keys.sorted().map { key in
          ToolField(key: key, value: value(dictionary[key] as Any, depth: depth + 1))
        })
    // swiftlint:disable:next legacy_objc_type
    case let list as [Any] where list.allSatisfy({ $0 is String || $0 is NSNumber }):
      return .scalar(list.map { "\(value($0, depth: depth + 1).text)" }.joined(separator: ", "))
    default:
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
      return .code(data.flatMap { String(data: $0, encoding: .utf8) } ?? "\(object)")
    }
  }

  /// The value as one line of text.
  var text: String {
    switch self {
    case .scalar(let text), .code(let text): text
    case .empty: "null"
    case .fields(let fields): fields.map { "\($0.key): \($0.value.text)" }.joined(separator: ", ")
    }
  }
}

/// One labeled value.
nonisolated struct ToolField: Hashable, Sendable, Identifiable {
  let key: String
  let value: ToolFieldValue
  var id: String { key }
}

/// The labeled values of an input or result.
struct ToolFieldsGrid: View {
  let fields: [ToolField]

  var body: some View {
    Grid(alignment: .topLeading, horizontalSpacing: Theme.Spacing.medium, verticalSpacing: 6) {
      ForEach(fields) { field in
        GridRow {
          Text(field.key)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
          value(field.value)
        }
      }
    }
  }

  @ViewBuilder private func value(_ value: ToolFieldValue) -> some View {
    switch value {
    case .scalar(let text):
      Text(verbatim: text.isEmpty ? "\u{201C}\u{201D}" : text)
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    case .empty:
      Text("null").font(.callout.monospaced()).foregroundStyle(.secondary)
    case .fields(let fields):
      Self(fields: fields)
    case .code(let code):
      CodeBlockView(code: code, language: "json", maxLines: 12)
    }
  }
}

/// A tool call's input and result as fields, the web's default view, with Raw beside it.
struct ToolFieldsBody: View {
  let input: [ToolField]
  let output: String?

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      if !input.isEmpty {
        label("Input")
        ToolFieldsGrid(fields: input)
      }
      if let output {
        label("Result")
        result(output)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private func result(_ output: String) -> some View {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let fields = ToolFieldValue.fields(json: trimmed)
    if !fields.isEmpty {
      ToolFieldsGrid(fields: fields)
    } else if trimmed.isEmpty {
      Text("No output").font(.callout).foregroundStyle(.secondary)
    } else if !trimmed.contains("\n"), trimmed.count <= 200 {
      Text(verbatim: trimmed).font(.callout).textSelection(.enabled)
    } else {
      CodeBlockView(code: output, language: nil, maxLines: 30)
    }
  }

  private func label(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .textCase(.uppercase)
  }
}
