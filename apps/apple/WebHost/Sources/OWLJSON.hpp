// JSON helpers for the structured 1.1 fields (owl_protocol.h, "Structured 1.1 fields"), built on
// CEF's value types and parser. Host side only.
#pragma once

#include <string>
#include <vector>

#include "include/cef_parser.h"
#include "include/cef_values.h"

namespace owl {

inline std::string WriteJSON(CefRefPtr<CefDictionaryValue> object) {
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetDictionary(object);
  return CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
}

inline std::string WriteJSON(CefRefPtr<CefListValue> list) {
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetList(list);
  return CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
}

inline CefRefPtr<CefListValue> StringList(const std::vector<std::string>& strings) {
  CefRefPtr<CefListValue> list = CefListValue::Create();
  for (size_t index = 0; index < strings.size(); ++index) {
    list->SetString(index, strings[index]);
  }
  return list;
}

/// Parses a JSON array of strings. False when `json` is not one.
inline bool ParseStringList(const std::string& json, std::vector<std::string>* out) {
  CefRefPtr<CefValue> value = CefParseJSON(json, JSON_PARSER_RFC);
  if (!value || value->GetType() != VTYPE_LIST) {
    return false;
  }
  CefRefPtr<CefListValue> list = value->GetList();
  for (size_t index = 0; index < list->GetSize(); ++index) {
    if (list->GetType(index) != VTYPE_STRING) {
      return false;
    }
    out->push_back(list->GetString(index).ToString());
  }
  return true;
}

/// Parses a JSON object. Null when `json` is not one.
inline CefRefPtr<CefDictionaryValue> ParseObject(const std::string& json) {
  CefRefPtr<CefValue> value = CefParseJSON(json, JSON_PARSER_RFC);
  if (!value || value->GetType() != VTYPE_DICTIONARY) {
    return nullptr;
  }
  return value->GetDictionary();
}

}  // namespace owl
