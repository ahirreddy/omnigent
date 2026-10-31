import Foundation

public enum DecisionValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case boolean(Bool)
  case strings([String])

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if let string = try? value.decode(String.self) {
      self = .string(string)
    } else if let boolean = try? value.decode(Bool.self) {
      self = .boolean(boolean)
    } else if let number = try? value.decode(Double.self), number.isFinite {
      self = .number(number)
    } else {
      self = .strings(try value.decode([String].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .boolean(let value): try container.encode(value)
    case .strings(let values): try container.encode(values)
    }
  }
}

public struct DecisionFormOption: Identifiable, Codable, Equatable, Sendable {
  public var id: String { value }
  public let value: String
  public let label: String
  public let detail: String

  public init(value: String, label: String? = nil, detail: String = "") {
    self.value = value
    self.label = label ?? value
    self.detail = detail
  }
}

public struct DecisionFormField: Identifiable, Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case text, number, integer, boolean, singleChoice, multipleChoice
  }
  public var id: String { key }
  public let key: String
  public let title: String
  public let detail: String
  public let kind: Kind
  public let required: Bool
  public let options: [DecisionFormOption]
  public let allowsCustom: Bool
  public let isSecret: Bool
  public let minimum: Double?
  public let maximum: Double?
  public let minLength: Int?
  public let maxLength: Int?
  public let minItems: Int?
  public let maxItems: Int?

  public init(
    key: String, title: String, detail: String = "", kind: Kind, required: Bool = true,
    options: [DecisionFormOption] = [], allowsCustom: Bool = false, isSecret: Bool = false,
    minimum: Double? = nil, maximum: Double? = nil,
    minLength: Int? = nil, maxLength: Int? = nil, minItems: Int? = nil, maxItems: Int? = nil
  ) {
    self.key = key
    self.title = title
    self.detail = detail
    self.kind = kind
    self.required = required
    self.options = options
    self.allowsCustom = allowsCustom
    self.isSecret = isSecret
    self.minimum = minimum
    self.maximum = maximum
    self.minLength = minLength
    self.maxLength = maxLength
    self.minItems = minItems
    self.maxItems = maxItems
  }

  public func validationError(value: DecisionValue?) -> String? {
    guard let value else { return required ? "Answer \(title)." : nil }
    switch (kind, value) {
    case (.text, .string(let text)), (.singleChoice, .string(let text)):
      if required && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "Answer \(title)."
      }
      if let minLength, text.count < minLength {
        return "\(title) needs at least \(minLength) characters."
      }
      if let maxLength, text.count > maxLength {
        return "\(title) allows at most \(maxLength) characters."
      }
      if kind == .singleChoice && !allowsCustom && !options.contains(where: { $0.value == text }) {
        return "Choose an available answer for \(title)."
      }
    case (.number, .number(let number)), (.integer, .number(let number)):
      guard number.isFinite, kind != .integer || number.rounded() == number else {
        return "Enter a valid \(kind == .integer ? "whole number" : "number") for \(title)."
      }
      if let minimum, number < minimum {
        return "\(title) must be at least \(minimum.formatted())."
      }
      if let maximum, number > maximum { return "\(title) must be at most \(maximum.formatted())." }
    case (.boolean, .boolean): break
    case (.multipleChoice, .strings(let values)):
      if values.count < (minItems ?? (required ? 1 : 0)) { return "Choose an answer for \(title)." }
      if let maxItems, values.count > maxItems {
        return "Choose at most \(maxItems) answers for \(title)."
      }
      if Set(values).count != values.count
        || values.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
      {
        return "Choose distinct, nonempty answers for \(title)."
      }
      if !allowsCustom
        && values.contains(where: { value in !options.contains(where: { $0.value == value }) })
      {
        return "Choose available answers for \(title)."
      }
    default: return "Enter a valid answer for \(title)."
    }
    return nil
  }
}

public struct DecisionForm: Codable, Equatable, Sendable {
  public let fields: [DecisionFormField]

  public init(fields: [DecisionFormField]) { self.fields = fields }

  public func validationError(values: [String: DecisionValue]) -> String? {
    if values.keys.contains(where: { key in !fields.contains(where: { $0.key == key }) }) {
      return "This response contains an unknown field."
    }
    return fields.lazy.compactMap { $0.validationError(value: values[$0.key]) }.first
  }
}

extension DecisionForm {
  static func parseSchema(_ schema: [String: JSONValue]) -> DecisionForm? {
    guard let properties = schema["properties"]?.object, !properties.isEmpty,
      properties.count <= 32,
      Set(schema.keys).isSubset(of: [
        "type", "properties", "required", "title", "description", "$schema", "additionalProperties",
      ]),
      schema["type"] == nil || schema["type"] == .string("object")
    else { return nil }
    if let value = schema["required"], value.array == nil { return nil }
    if let additional = schema["additionalProperties"],
      additional != .bool(true) && additional != .bool(false)
    {
      return nil
    }
    let requiredValues = schema["required"]?.array ?? []
    guard requiredValues.allSatisfy({ $0.string != nil }) else { return nil }
    let required = Set(requiredValues.compactMap(\.string))
    guard required.isSubset(of: Set(properties.keys)) else { return nil }
    var fields: [DecisionFormField] = []
    for key in properties.keys.sorted() {
      guard let property = properties[key]?.object,
        Set(property.keys).isSubset(of: [
          "type", "title", "description", "enum", "enumNames", "default", "minimum", "maximum",
          "minLength", "maxLength", "minItems", "maxItems", "items", "uniqueItems",
        ])
      else { return nil }
      for key in ["minimum", "maximum"] {
        if let value = property[key], number(value) == nil { return nil }
      }
      for key in ["minLength", "maxLength", "minItems", "maxItems"] {
        if let value = property[key] {
          guard let number = number(value), number >= 0, number.rounded() == number,
            number < Double(Int.max)
          else { return nil }
        }
      }
      for (minimum, maximum) in [
        ("minimum", "maximum"), ("minLength", "maxLength"), ("minItems", "maxItems"),
      ] {
        if let lower = number(property[minimum]), let upper = number(property[maximum]),
          lower > upper
        {
          return nil
        }
      }
      let type = property["type"]?.string ?? (property["enum"] != nil ? "string" : "")
      let kind: DecisionFormField.Kind
      var options: [DecisionFormOption] = []
      switch type {
      case "string":
        if let values = property["enum"]?.array {
          guard !values.isEmpty, values.count <= 100, values.allSatisfy({ $0.string != nil }) else {
            return nil
          }
          let labels = property["enumNames"]?.array?.compactMap(\.string) ?? []
          options = values.enumerated().map { index, value in
            DecisionFormOption(
              value: value.string!, label: labels.indices.contains(index) ? labels[index] : nil)
          }
          kind = .singleChoice
        } else {
          kind = .text
        }
      case "boolean": kind = .boolean
      case "number": kind = .number
      case "integer": kind = .integer
      case "array":
        guard let items = property["items"]?.object,
          Set(items.keys).isSubset(of: ["type", "enum", "enumNames"]),
          items["type"] == .string("string"), let values = items["enum"]?.array,
          !values.isEmpty, values.count <= 100, values.allSatisfy({ $0.string != nil })
        else { return nil }
        options = values.map { DecisionFormOption(value: $0.string!) }
        kind = .multipleChoice
      default: return nil
      }
      guard Set(options.map(\.value)).count == options.count else { return nil }
      if property["minimum"] != nil || property["maximum"] != nil {
        guard kind == .number || kind == .integer else { return nil }
      }
      if property["minLength"] != nil || property["maxLength"] != nil {
        guard kind == .text || kind == .singleChoice else { return nil }
      }
      if property["items"] != nil || property["minItems"] != nil || property["maxItems"] != nil
        || property["uniqueItems"] != nil
      {
        guard kind == .multipleChoice else { return nil }
        if let unique = property["uniqueItems"], unique != .bool(true) && unique != .bool(false) {
          return nil
        }
      }
      // Unsupported constraints never silently turn into a less restrictive native form.
      if property["enum"] != nil && kind != .singleChoice { return nil }
      let field = DecisionFormField(
        key: key, title: property["title"]?.string ?? key,
        detail: property["description"]?.string ?? "", kind: kind,
        required: required.contains(key), options: options,
        minimum: number(property["minimum"]), maximum: number(property["maximum"]),
        minLength: property["minLength"]?.int, maxLength: property["maxLength"]?.int,
        minItems: property["minItems"]?.int, maxItems: property["maxItems"]?.int)
      fields.append(field)
    }
    return DecisionForm(fields: fields)
  }

  static func parseQuestions(_ payload: JSONValue) -> DecisionForm? {
    guard let questions = payload.object?["questions"]?.array, !questions.isEmpty,
      questions.count <= 32
    else { return nil }
    var fields: [DecisionFormField] = []
    for question in questions {
      guard let object = question.object, let title = object["question"]?.string, !title.isEmpty,
        let rawOptions = object["options"]?.array, rawOptions.count <= 100
      else { return nil }
      var options: [DecisionFormOption] = []
      for raw in rawOptions {
        guard let option = raw.object, let label = option["label"]?.string, !label.isEmpty else {
          return nil
        }
        let detail = [option["description"]?.string, option["preview"]?.string].compactMap { $0 }
          .joined(separator: "\n\n")
        options.append(DecisionFormOption(value: label, detail: detail))
      }
      guard Set(options.map(\.value)).count == options.count else { return nil }
      let suppliedID = object["id"]?.string ?? ""
      fields.append(
        DecisionFormField(
          key: suppliedID.isEmpty ? title : suppliedID, title: title,
          detail: object["header"]?.string ?? "",
          kind: object["multiSelect"] == .bool(true) ? .multipleChoice : .singleChoice,
          options: options, allowsCustom: true, isSecret: object["isSecret"] == .bool(true)))
    }
    guard Set(fields.map(\.key)).count == fields.count else { return nil }
    return DecisionForm(fields: fields)
  }

  private static func number(_ value: JSONValue?) -> Double? {
    guard case .number(let number) = value, number.isFinite else { return nil }
    return number
  }
}
