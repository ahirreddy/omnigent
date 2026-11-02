// A small JSON value with a strict RFC 8259 parser and a compact writer. The host speaks JSON
// control messages (design doc section 5.3) and must not depend on CEF to do so, so tests and
// tools can run without Chromium.
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace rb {

class Json {
 public:
  enum class Type { kNull, kBool, kNumber, kString, kArray, kObject };
  using Array = std::vector<Json>;
  using Object = std::map<std::string, Json>;

  Json() = default;
  Json(std::nullptr_t) {}                                 // NOLINT(google-explicit-constructor)
  Json(bool value) : type_(Type::kBool), bool_(value) {}  // NOLINT
  Json(int value)
      : type_(Type::kNumber), number_(value), is_integer_(true), integer_(value) {}  // NOLINT
  Json(int64_t value)                                                                // NOLINT
      : type_(Type::kNumber),
        number_(static_cast<double>(value)),
        is_integer_(true),
        integer_(value) {}
  Json(uint64_t value)  // NOLINT
      : type_(Type::kNumber),
        number_(static_cast<double>(value)),
        is_integer_(true),
        integer_(static_cast<int64_t>(value)) {}
  Json(uint32_t value) : Json(static_cast<int64_t>(value)) {}                   // NOLINT
  Json(double value) : type_(Type::kNumber), number_(value) {}                  // NOLINT
  Json(const char* value) : type_(Type::kString), string_(value) {}             // NOLINT
  Json(std::string value) : type_(Type::kString), string_(std::move(value)) {}  // NOLINT
  Json(std::string_view value) : type_(Type::kString), string_(value) {}        // NOLINT
  Json(Array value)
      : type_(Type::kArray), array_(std::make_shared<Array>(std::move(value))) {}  // NOLINT
  Json(Object value)                                                               // NOLINT
      : type_(Type::kObject), object_(std::make_shared<Object>(std::move(value))) {}

  static Json MakeObject() { return Json(Object{}); }
  static Json MakeArray() { return Json(Array{}); }

  /// Parses one JSON document. On failure returns nullopt and sets `error`.
  static std::optional<Json> Parse(std::string_view text, std::string* error);

  /// Compact serialization with keys in sorted order.
  std::string Dump() const;

  Type type() const { return type_; }
  bool is_null() const { return type_ == Type::kNull; }
  bool is_bool() const { return type_ == Type::kBool; }
  bool is_number() const { return type_ == Type::kNumber; }
  bool is_string() const { return type_ == Type::kString; }
  bool is_array() const { return type_ == Type::kArray; }
  bool is_object() const { return type_ == Type::kObject; }

  bool as_bool() const { return bool_; }
  double as_double() const { return number_; }
  /// The value as an integer when it is an integral number in range.
  std::optional<int64_t> as_integer() const;
  const std::string& as_string() const { return string_; }
  const Array& as_array() const;
  const Object& as_object() const;

  /// Object member lookup; null when absent or when this is not an object.
  const Json* Find(std::string_view key) const;
  std::optional<std::string> GetString(std::string_view key) const;
  std::optional<double> GetNumber(std::string_view key) const;
  std::optional<int64_t> GetInteger(std::string_view key) const;
  std::optional<bool> GetBool(std::string_view key) const;

  /// Sets an object member. Converts null to an empty object first.
  Json& Set(std::string key, Json value);
  /// Appends to an array. Converts null to an empty array first.
  Json& Push(Json value);

  bool operator==(const Json& other) const;
  bool operator!=(const Json& other) const { return !(*this == other); }

 private:
  void DumpTo(std::string* out) const;

  Type type_ = Type::kNull;
  bool bool_ = false;
  double number_ = 0;
  bool is_integer_ = false;
  int64_t integer_ = 0;
  std::string string_;
  std::shared_ptr<Array> array_;
  std::shared_ptr<Object> object_;
};

/// Writes `text` as a JSON string literal (with quotes) to `out`.
void AppendJsonString(std::string_view text, std::string* out);

}  // namespace rb
