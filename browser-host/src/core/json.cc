#include "core/json.h"

#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace rb {

namespace {

constexpr int kMaxDepth = 64;

class Parser {
 public:
  Parser(std::string_view text, std::string* error) : text_(text), error_(error) {}

  std::optional<Json> ParseDocument() {
    SkipSpace();
    std::optional<Json> value = ParseValue(0);
    if (!value) {
      return std::nullopt;
    }
    SkipSpace();
    if (position_ != text_.size()) {
      return Fail("trailing characters after the JSON value");
    }
    return value;
  }

 private:
  std::nullopt_t Fail(const char* message) {
    if (error_ != nullptr) {
      *error_ = std::string(message) + " at offset " + std::to_string(position_);
    }
    return std::nullopt;
  }

  void SkipSpace() {
    while (position_ < text_.size()) {
      const char character = text_[position_];
      if (character != ' ' && character != '\t' && character != '\n' && character != '\r') {
        return;
      }
      ++position_;
    }
  }

  bool Consume(std::string_view literal) {
    if (text_.substr(position_, literal.size()) == literal) {
      position_ += literal.size();
      return true;
    }
    return false;
  }

  std::optional<Json> ParseValue(int depth) {
    if (depth > kMaxDepth) {
      return Fail("JSON nesting is too deep");
    }
    if (position_ >= text_.size()) {
      return Fail("unexpected end of input");
    }
    switch (text_[position_]) {
      case '{':
        return ParseObject(depth);
      case '[':
        return ParseArray(depth);
      case '"': {
        std::string value;
        if (!ParseString(&value)) {
          return std::nullopt;
        }
        return Json(std::move(value));
      }
      case 't':
        if (Consume("true")) {
          return Json(true);
        }
        return Fail("invalid literal");
      case 'f':
        if (Consume("false")) {
          return Json(false);
        }
        return Fail("invalid literal");
      case 'n':
        if (Consume("null")) {
          return Json(nullptr);
        }
        return Fail("invalid literal");
      default:
        return ParseNumber();
    }
  }

  std::optional<Json> ParseObject(int depth) {
    ++position_;
    Json::Object object;
    SkipSpace();
    if (Consume("}")) {
      return Json(std::move(object));
    }
    while (true) {
      SkipSpace();
      if (position_ >= text_.size() || text_[position_] != '"') {
        return Fail("expected an object key");
      }
      std::string key;
      if (!ParseString(&key)) {
        return std::nullopt;
      }
      SkipSpace();
      if (!Consume(":")) {
        return Fail("expected ':'");
      }
      SkipSpace();
      std::optional<Json> value = ParseValue(depth + 1);
      if (!value) {
        return std::nullopt;
      }
      object[std::move(key)] = std::move(*value);
      SkipSpace();
      if (Consume("}")) {
        return Json(std::move(object));
      }
      if (!Consume(",")) {
        return Fail("expected ',' or '}'");
      }
    }
  }

  std::optional<Json> ParseArray(int depth) {
    ++position_;
    Json::Array array;
    SkipSpace();
    if (Consume("]")) {
      return Json(std::move(array));
    }
    while (true) {
      SkipSpace();
      std::optional<Json> value = ParseValue(depth + 1);
      if (!value) {
        return std::nullopt;
      }
      array.push_back(std::move(*value));
      SkipSpace();
      if (Consume("]")) {
        return Json(std::move(array));
      }
      if (!Consume(",")) {
        return Fail("expected ',' or ']'");
      }
    }
  }

  bool ParseHex4(uint32_t* out) {
    if (text_.size() - position_ < 4) {
      Fail("truncated \\u escape");
      return false;
    }
    uint32_t value = 0;
    for (int index = 0; index < 4; ++index) {
      const char character = text_[position_++];
      value <<= 4;
      if (character >= '0' && character <= '9') {
        value |= static_cast<uint32_t>(character - '0');
      } else if (character >= 'a' && character <= 'f') {
        value |= static_cast<uint32_t>(character - 'a' + 10);
      } else if (character >= 'A' && character <= 'F') {
        value |= static_cast<uint32_t>(character - 'A' + 10);
      } else {
        Fail("invalid \\u escape");
        return false;
      }
    }
    *out = value;
    return true;
  }

  static void AppendUtf8(uint32_t code_point, std::string* out) {
    if (code_point < 0x80) {
      out->push_back(static_cast<char>(code_point));
    } else if (code_point < 0x800) {
      out->push_back(static_cast<char>(0xC0 | (code_point >> 6)));
      out->push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
    } else if (code_point < 0x10000) {
      out->push_back(static_cast<char>(0xE0 | (code_point >> 12)));
      out->push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3F)));
      out->push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
    } else {
      out->push_back(static_cast<char>(0xF0 | (code_point >> 18)));
      out->push_back(static_cast<char>(0x80 | ((code_point >> 12) & 0x3F)));
      out->push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3F)));
      out->push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
    }
  }

  bool ParseString(std::string* out) {
    ++position_;  // Opening quote.
    while (position_ < text_.size()) {
      const char character = text_[position_++];
      if (character == '"') {
        return true;
      }
      if (static_cast<unsigned char>(character) < 0x20) {
        Fail("unescaped control character in string");
        return false;
      }
      if (character != '\\') {
        out->push_back(character);
        continue;
      }
      if (position_ >= text_.size()) {
        break;
      }
      const char escape = text_[position_++];
      switch (escape) {
        case '"':
        case '\\':
        case '/':
          out->push_back(escape);
          break;
        case 'b':
          out->push_back('\b');
          break;
        case 'f':
          out->push_back('\f');
          break;
        case 'n':
          out->push_back('\n');
          break;
        case 'r':
          out->push_back('\r');
          break;
        case 't':
          out->push_back('\t');
          break;
        case 'u': {
          uint32_t code_point = 0;
          if (!ParseHex4(&code_point)) {
            return false;
          }
          if (code_point >= 0xD800 && code_point <= 0xDBFF) {
            uint32_t low = 0;
            if (!Consume("\\u") || !ParseHex4(&low) || low < 0xDC00 || low > 0xDFFF) {
              Fail("unpaired UTF-16 surrogate");
              return false;
            }
            code_point = 0x10000 + ((code_point - 0xD800) << 10) + (low - 0xDC00);
          } else if (code_point >= 0xDC00 && code_point <= 0xDFFF) {
            Fail("unpaired UTF-16 surrogate");
            return false;
          }
          AppendUtf8(code_point, out);
          break;
        }
        default:
          Fail("invalid escape");
          return false;
      }
    }
    Fail("unterminated string");
    return false;
  }

  std::optional<Json> ParseNumber() {
    const size_t start = position_;
    bool integral = true;
    Consume("-");
    if (position_ >= text_.size() || text_[position_] < '0' || text_[position_] > '9') {
      return Fail("invalid value");
    }
    if (text_[position_] == '0') {
      ++position_;
    } else {
      while (position_ < text_.size() && text_[position_] >= '0' && text_[position_] <= '9') {
        ++position_;
      }
    }
    if (position_ < text_.size() && text_[position_] == '.') {
      integral = false;
      ++position_;
      const size_t digits = position_;
      while (position_ < text_.size() && text_[position_] >= '0' && text_[position_] <= '9') {
        ++position_;
      }
      if (position_ == digits) {
        return Fail("expected digits after '.'");
      }
    }
    if (position_ < text_.size() && (text_[position_] == 'e' || text_[position_] == 'E')) {
      integral = false;
      ++position_;
      if (position_ < text_.size() && (text_[position_] == '+' || text_[position_] == '-')) {
        ++position_;
      }
      const size_t digits = position_;
      while (position_ < text_.size() && text_[position_] >= '0' && text_[position_] <= '9') {
        ++position_;
      }
      if (position_ == digits) {
        return Fail("expected exponent digits");
      }
    }
    const std::string literal(text_.substr(start, position_ - start));
    if (integral) {
      char* end = nullptr;
      errno = 0;
      const long long value = std::strtoll(literal.c_str(), &end, 10);
      if (errno == 0 && end == literal.c_str() + literal.size()) {
        return Json(static_cast<int64_t>(value));
      }
    }
    char* end = nullptr;
    const double value = std::strtod(literal.c_str(), &end);
    if (end != literal.c_str() + literal.size() || !std::isfinite(value)) {
      return Fail("number out of range");
    }
    return Json(value);
  }

  std::string_view text_;
  std::string* error_;
  size_t position_ = 0;
};

}  // namespace

void AppendJsonString(std::string_view text, std::string* out) {
  out->push_back('"');
  for (const char character : text) {
    const auto byte = static_cast<unsigned char>(character);
    switch (character) {
      case '"':
        out->append("\\\"");
        break;
      case '\\':
        out->append("\\\\");
        break;
      case '\n':
        out->append("\\n");
        break;
      case '\r':
        out->append("\\r");
        break;
      case '\t':
        out->append("\\t");
        break;
      case '\b':
        out->append("\\b");
        break;
      case '\f':
        out->append("\\f");
        break;
      default:
        if (byte < 0x20) {
          char escaped[8];
          std::snprintf(escaped, sizeof(escaped), "\\u%04x", byte);
          out->append(escaped);
        } else {
          out->push_back(character);
        }
    }
  }
  out->push_back('"');
}

std::optional<Json> Json::Parse(std::string_view text, std::string* error) {
  return Parser(text, error).ParseDocument();
}

std::optional<int64_t> Json::as_integer() const {
  if (type_ != Type::kNumber) {
    return std::nullopt;
  }
  if (is_integer_) {
    return integer_;
  }
  if (std::floor(number_) == number_ && std::fabs(number_) < 9.007199254740992e15) {
    return static_cast<int64_t>(number_);
  }
  return std::nullopt;
}

const Json::Array& Json::as_array() const {
  static const Array kEmpty;
  return array_ ? *array_ : kEmpty;
}

const Json::Object& Json::as_object() const {
  static const Object kEmpty;
  return object_ ? *object_ : kEmpty;
}

const Json* Json::Find(std::string_view key) const {
  if (type_ != Type::kObject || !object_) {
    return nullptr;
  }
  auto found = object_->find(std::string(key));
  return found == object_->end() ? nullptr : &found->second;
}

std::optional<std::string> Json::GetString(std::string_view key) const {
  const Json* value = Find(key);
  if (value == nullptr || !value->is_string()) {
    return std::nullopt;
  }
  return value->as_string();
}

std::optional<double> Json::GetNumber(std::string_view key) const {
  const Json* value = Find(key);
  if (value == nullptr || !value->is_number()) {
    return std::nullopt;
  }
  return value->as_double();
}

std::optional<int64_t> Json::GetInteger(std::string_view key) const {
  const Json* value = Find(key);
  if (value == nullptr) {
    return std::nullopt;
  }
  return value->as_integer();
}

std::optional<bool> Json::GetBool(std::string_view key) const {
  const Json* value = Find(key);
  if (value == nullptr || !value->is_bool()) {
    return std::nullopt;
  }
  return value->as_bool();
}

Json& Json::Set(std::string key, Json value) {
  if (type_ != Type::kObject) {
    *this = MakeObject();
  }
  if (object_.use_count() > 1) {
    object_ = std::make_shared<Object>(*object_);  // Copy on write: values share storage.
  }
  (*object_)[std::move(key)] = std::move(value);
  return *this;
}

Json& Json::Push(Json value) {
  if (type_ != Type::kArray) {
    *this = MakeArray();
  }
  if (array_.use_count() > 1) {
    array_ = std::make_shared<Array>(*array_);
  }
  array_->push_back(std::move(value));
  return *this;
}

bool Json::operator==(const Json& other) const {
  if (type_ != other.type_) {
    return false;
  }
  switch (type_) {
    case Type::kNull:
      return true;
    case Type::kBool:
      return bool_ == other.bool_;
    case Type::kNumber:
      if (is_integer_ && other.is_integer_) {
        return integer_ == other.integer_;
      }
      return number_ == other.number_;
    case Type::kString:
      return string_ == other.string_;
    case Type::kArray:
      return as_array() == other.as_array();
    case Type::kObject:
      return as_object() == other.as_object();
  }
  return false;
}

std::string Json::Dump() const {
  std::string out;
  DumpTo(&out);
  return out;
}

void Json::DumpTo(std::string* out) const {
  switch (type_) {
    case Type::kNull:
      out->append("null");
      return;
    case Type::kBool:
      out->append(bool_ ? "true" : "false");
      return;
    case Type::kNumber: {
      if (is_integer_) {
        out->append(std::to_string(integer_));
        return;
      }
      if (std::floor(number_) == number_ && std::fabs(number_) < 1e15) {
        out->append(std::to_string(static_cast<int64_t>(number_)));
        return;
      }
      char buffer[32];
      std::snprintf(buffer, sizeof(buffer), "%.17g", number_);
      out->append(buffer);
      return;
    }
    case Type::kString:
      AppendJsonString(string_, out);
      return;
    case Type::kArray: {
      out->push_back('[');
      bool first = true;
      for (const Json& item : as_array()) {
        if (!first) {
          out->push_back(',');
        }
        first = false;
        item.DumpTo(out);
      }
      out->push_back(']');
      return;
    }
    case Type::kObject: {
      out->push_back('{');
      bool first = true;
      for (const auto& [key, value] : as_object()) {
        if (!first) {
          out->push_back(',');
        }
        first = false;
        AppendJsonString(key, out);
        out->push_back(':');
        value.DumpTo(out);
      }
      out->push_back('}');
      return;
    }
  }
}

}  // namespace rb
