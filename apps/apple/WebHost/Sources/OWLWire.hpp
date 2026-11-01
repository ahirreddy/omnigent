// Encoder and decoder for OWL payloads (owl_protocol.h). Header-only; host side only.
#pragma once

#include <cstdint>
#include <cstring>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "owl_protocol.h"

static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "The OWL wire format is little-endian.");

namespace owl {

class Encoder {
 public:
  Encoder& U64(OWLField tag, uint64_t value) {
    return Put(tag, OWLFieldTypeUInt64, &value, sizeof(value));
  }
  Encoder& I64(OWLField tag, int64_t value) {
    return Put(tag, OWLFieldTypeInt64, &value, sizeof(value));
  }
  Encoder& Double(OWLField tag, double value) {
    return Put(tag, OWLFieldTypeDouble, &value, sizeof(value));
  }
  Encoder& Bool(OWLField tag, bool value) {
    const uint8_t byte = value ? 1 : 0;
    return Put(tag, OWLFieldTypeBool, &byte, 1);
  }
  Encoder& String(OWLField tag, std::string_view value) {
    return Put(tag, OWLFieldTypeString, value.data(), value.size());
  }
  Encoder& Bytes(OWLField tag, const void* data, size_t length) {
    return Put(tag, OWLFieldTypeBytes, data, length);
  }

  const std::vector<uint8_t>& data() const { return data_; }

 private:
  Encoder& Put(OWLField tag, OWLFieldType type, const void* bytes, size_t length) {
    OWLFieldHeader header{static_cast<uint16_t>(tag), static_cast<uint8_t>(type), 0,
                          static_cast<uint32_t>(length)};
    const auto* header_bytes = reinterpret_cast<const uint8_t*>(&header);
    data_.insert(data_.end(), header_bytes, header_bytes + sizeof(header));
    if (length > 0) {
      const auto* value_bytes = static_cast<const uint8_t*>(bytes);
      data_.insert(data_.end(), value_bytes, value_bytes + length);
    }
    return *this;
  }

  std::vector<uint8_t> data_;
};

class Decoder {
 public:
  /// Returns nullopt when a field header or value runs past the payload.
  static std::optional<Decoder> Parse(const uint8_t* data, size_t length) {
    Decoder decoder;
    size_t offset = 0;
    while (offset < length) {
      if (length - offset < sizeof(OWLFieldHeader)) {
        return std::nullopt;
      }
      OWLFieldHeader header;
      std::memcpy(&header, data + offset, sizeof(header));
      offset += sizeof(header);
      if (length - offset < header.length) {
        return std::nullopt;
      }
      decoder.fields_[header.tag] = Field{header.type, data + offset, header.length};
      offset += header.length;
    }
    return decoder;
  }

  std::optional<uint64_t> U64(OWLField tag) const { return Scalar<uint64_t>(tag, OWLFieldTypeUInt64); }
  std::optional<int64_t> I64(OWLField tag) const { return Scalar<int64_t>(tag, OWLFieldTypeInt64); }
  std::optional<double> Double(OWLField tag) const { return Scalar<double>(tag, OWLFieldTypeDouble); }
  std::optional<bool> Bool(OWLField tag) const {
    auto byte = Scalar<uint8_t>(tag, OWLFieldTypeBool);
    if (!byte) {
      return std::nullopt;
    }
    return *byte != 0;
  }
  std::optional<std::string> String(OWLField tag) const {
    auto found = fields_.find(static_cast<uint16_t>(tag));
    if (found == fields_.end() || found->second.type != OWLFieldTypeString) {
      return std::nullopt;
    }
    return std::string(reinterpret_cast<const char*>(found->second.data), found->second.length);
  }

 private:
  struct Field {
    uint8_t type;
    const uint8_t* data;
    uint32_t length;
  };

  template <typename T>
  std::optional<T> Scalar(OWLField tag, OWLFieldType type) const {
    auto found = fields_.find(static_cast<uint16_t>(tag));
    if (found == fields_.end() || found->second.type != type || found->second.length != sizeof(T)) {
      return std::nullopt;
    }
    T value;
    std::memcpy(&value, found->second.data, sizeof(T));
    return value;
  }

  std::map<uint16_t, Field> fields_;
};

}  // namespace owl
