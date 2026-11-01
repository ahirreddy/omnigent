// Declarative navigation rules the client pushes for a view (SetNavigationRules), enforced
// synchronously in CefRequestHandler::OnBeforeBrowse, so redirects and page-initiated navigations
// are covered too. The Swift twin is OmnigentBrowser's AgentURLRules; both follow the "Rules"
// schema in owl_protocol.h. See DESIGN.md, "Agent browser actions".
#pragma once

#include <set>
#include <string>
#include <vector>

namespace owl {

struct NavigationRules {
  bool enabled = false;
  /// Lowercase schemes without the colon. Empty allows every scheme.
  std::set<std::string> schemes;
  /// Lowercase host patterns. A pattern matches the host itself and its subdomains.
  std::vector<std::string> allow;
  std::vector<std::string> deny;
  bool block_private_addresses = false;
  bool allow_loopback = false;

  /// Parses the JSON rules object. An empty string disables the rules.
  static bool Parse(const std::string& json, NavigationRules* out, std::string* error);

  /// An empty string when `url` may load, otherwise why it may not.
  std::string Check(const std::string& url) const;
};

/// Whether `host` matches `pattern` (the host itself or one of its subdomains).
bool HostMatches(const std::string& host, const std::string& pattern);

/// Whether `host` is a loopback name or address ("localhost", 127.0.0.0/8, ::1).
bool IsLoopbackHost(const std::string& host);

/// Whether `host` is an IP literal outside public unicast space. Names are not resolved.
bool IsPrivateAddressLiteral(const std::string& host);

}  // namespace owl
