#include "OWLNavigationRules.hpp"

#include <arpa/inet.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cstring>

#include "include/cef_parser.h"

namespace owl {

namespace {

std::string Lowercase(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char character) { return static_cast<char>(std::tolower(character)); });
  return value;
}

/// Strips the "*." or "." prefix a caller may write before a domain pattern.
std::string NormalizedPattern(std::string pattern) {
  pattern = Lowercase(pattern);
  if (pattern.rfind("*.", 0) == 0) {
    pattern.erase(0, 2);
  } else if (pattern.rfind('.', 0) == 0) {
    pattern.erase(0, 1);
  }
  return pattern;
}

bool ReadStrings(CefRefPtr<CefDictionaryValue> object, const char* key,
                 std::vector<std::string>* out, std::string* error) {
  if (!object->HasKey(key)) {
    return true;
  }
  CefRefPtr<CefListValue> list = object->GetList(key);
  if (!list) {
    *error = std::string("\"") + key + "\" must be an array of strings.";
    return false;
  }
  for (size_t index = 0; index < list->GetSize(); ++index) {
    if (list->GetType(index) != VTYPE_STRING) {
      *error = std::string("\"") + key + "\" must contain only strings.";
      return false;
    }
    out->push_back(list->GetString(index).ToString());
  }
  return true;
}

bool IsPrivateIPv4(const std::array<uint8_t, 4>& octets) {
  const uint8_t a = octets[0];
  const uint8_t b = octets[1];
  const uint8_t c = octets[2];
  if (a == 0 || a == 10 || a == 127) {
    return true;  // "this host", RFC 1918, loopback
  }
  if (a == 100 && b >= 64 && b <= 127) {
    return true;  // shared address space
  }
  if ((a == 169 && b == 254) || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168)) {
    return true;  // link-local (cloud metadata), RFC 1918
  }
  if ((a == 192 && b == 0 && (c == 0 || c == 2)) || (a == 198 && (b == 18 || b == 19)) ||
      (a == 198 && b == 51 && c == 100) || (a == 203 && b == 0 && c == 113)) {
    return true;  // protocol assignments, benchmarking, documentation
  }
  return a >= 224;  // multicast, reserved, broadcast
}

/// The bracket-free address text of an IPv6 host such as "[::1]".
std::string Unbracketed(const std::string& host) {
  if (host.size() >= 2 && host.front() == '[' && host.back() == ']') {
    return host.substr(1, host.size() - 2);
  }
  return host;
}

bool ParseIPv4(const std::string& host, std::array<uint8_t, 4>* octets) {
  in_addr address{};
  if (inet_pton(AF_INET, host.c_str(), &address) != 1) {
    return false;
  }
  std::memcpy(octets->data(), &address.s_addr, 4);
  return true;
}

bool ParseIPv6(const std::string& host, std::array<uint8_t, 16>* bytes) {
  in6_addr address{};
  if (inet_pton(AF_INET6, Unbracketed(host).c_str(), &address) != 1) {
    return false;
  }
  std::memcpy(bytes->data(), &address, 16);
  return true;
}

bool IsPrivateIPv6(const std::array<uint8_t, 16>& bytes) {
  bool mapped = true;
  for (size_t index = 0; index < 10; ++index) {
    mapped = mapped && bytes[index] == 0;
  }
  if (mapped && bytes[10] == 0xff && bytes[11] == 0xff) {
    return IsPrivateIPv4({bytes[12], bytes[13], bytes[14], bytes[15]});
  }
  // Only 2000::/3 is global unicast; 2001:db8::/32 is documentation.
  if ((bytes[0] & 0xe0) != 0x20) {
    return true;
  }
  return bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8;
}

}  // namespace

bool HostMatches(const std::string& host, const std::string& pattern) {
  const std::string normalized = NormalizedPattern(pattern);
  if (normalized.empty()) {
    return false;
  }
  const std::string lower = Lowercase(host);
  if (lower == normalized) {
    return true;
  }
  return lower.size() > normalized.size() &&
         lower.compare(lower.size() - normalized.size(), normalized.size(), normalized) == 0 &&
         lower[lower.size() - normalized.size() - 1] == '.';
}

bool IsLoopbackHost(const std::string& host) {
  const std::string lower = Lowercase(host);
  if (lower == "localhost" || HostMatches(lower, "localhost")) {
    return true;
  }
  std::array<uint8_t, 4> v4{};
  if (ParseIPv4(lower, &v4)) {
    return v4[0] == 127;
  }
  std::array<uint8_t, 16> v6{};
  if (ParseIPv6(lower, &v6)) {
    for (size_t index = 0; index < 15; ++index) {
      if (v6[index] != 0) {
        return false;
      }
    }
    return v6[15] == 1;
  }
  return false;
}

bool IsPrivateAddressLiteral(const std::string& host) {
  std::array<uint8_t, 4> v4{};
  if (ParseIPv4(host, &v4)) {
    return IsPrivateIPv4(v4);
  }
  std::array<uint8_t, 16> v6{};
  if (ParseIPv6(host, &v6)) {
    return IsPrivateIPv6(v6);
  }
  return false;
}

bool NavigationRules::Parse(const std::string& json, NavigationRules* out, std::string* error) {
  NavigationRules rules;
  if (json.empty()) {
    *out = rules;
    return true;
  }
  CefRefPtr<CefValue> value = CefParseJSON(json, JSON_PARSER_RFC);
  if (!value || value->GetType() != VTYPE_DICTIONARY) {
    *error = "Navigation rules must be a JSON object.";
    return false;
  }
  CefRefPtr<CefDictionaryValue> object = value->GetDictionary();
  std::vector<std::string> schemes;
  if (!ReadStrings(object, "schemes", &schemes, error) ||
      !ReadStrings(object, "allow", &rules.allow, error) ||
      !ReadStrings(object, "deny", &rules.deny, error)) {
    return false;
  }
  for (const std::string& scheme : schemes) {
    rules.schemes.insert(Lowercase(scheme));
  }
  rules.block_private_addresses =
      object->HasKey("blockPrivateAddresses") && object->GetBool("blockPrivateAddresses");
  rules.allow_loopback = object->HasKey("allowLoopback") && object->GetBool("allowLoopback");
  rules.enabled = true;
  *out = rules;
  return true;
}

std::string NavigationRules::Check(const std::string& url) const {
  if (!enabled || url == "about:blank" || url == "about:srcdoc") {
    return "";
  }
  CefURLParts parts;
  if (!CefParseURL(url, parts)) {
    return "The URL could not be parsed.";
  }
  const std::string scheme = Lowercase(CefString(&parts.scheme).ToString());
  const std::string host = Lowercase(CefString(&parts.host).ToString());
  if (!schemes.empty() && schemes.count(scheme) == 0) {
    return "The scheme \"" + scheme + "\" is not allowed.";
  }
  for (const std::string& pattern : deny) {
    if (HostMatches(host, pattern)) {
      return "The host " + host + " is on the deny list.";
    }
  }
  const bool loopback = IsLoopbackHost(host);
  if (loopback && !allow_loopback && block_private_addresses) {
    return "Loopback hosts are not allowed.";
  }
  if (!loopback && block_private_addresses && IsPrivateAddressLiteral(host)) {
    return "The private address " + host + " is not allowed.";
  }
  if (!allow.empty()) {
    for (const std::string& pattern : allow) {
      if (HostMatches(host, pattern)) {
        return "";
      }
    }
    if (loopback && allow_loopback) {
      return "";
    }
    return "The host " + host + " is not on the allow list.";
  }
  return "";
}

}  // namespace owl
