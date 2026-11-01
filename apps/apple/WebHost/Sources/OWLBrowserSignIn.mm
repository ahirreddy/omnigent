// Protocol 1.3 sign-in plumbing: navigations to schemes Chromium does not render (Okta Verify's
// `com-okta-authenticator:`, `zoommtg:`, `mailto:`) are cancelled and offered to the client,
// which may open them with the OS after asking the user. The host never launches anything. See
// DESIGN.md, "Sign-in (protocol 1.3)".
#include "OWLBrowserClient.hpp"

#include <algorithm>
#include <cctype>
#include <iterator>

#include "OWLHost.hpp"
#include "include/cef_parser.h"

namespace owl {

namespace {

/// Long enough for Okta's signed challenge requests; longer URLs are reported, not forwarded.
constexpr size_t kMaxExternalURLLength = 32 * 1024;

/// Schemes Chromium renders or handles itself; everything else belongs to another app.
bool IsBrowserScheme(const std::string& scheme) {
  static const char* const kBrowser[] = {
      "http", "https", "file", "ftp", "data", "blob", "about", "javascript", "chrome",
      "chrome-error", "chrome-extension", "chrome-untrusted", "devtools", "view-source",
      "filesystem", "ws", "wss",
  };
  return std::any_of(std::begin(kBrowser), std::end(kBrowser),
                     [&](const char* browser) { return scheme == browser; });
}

std::string LowercaseScheme(const std::string& url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) {
    return "";
  }
  std::string scheme = CefString(&parts.scheme).ToString();
  std::transform(scheme.begin(), scheme.end(), scheme.begin(), [](unsigned char character) {
    return static_cast<char>(std::tolower(character));
  });
  return scheme;
}

}  // namespace

bool BrowserClient::ClientHandlesSignIn() const {
  return Host::Get().config().client_minor >= OWL_PROTOCOL_MINOR_SIGN_IN;
}

bool BrowserClient::HandOffExternalNavigation(CefRefPtr<CefFrame> frame, const std::string& url) {
  const std::string scheme = LowercaseScheme(url);
  if (scheme.empty() || IsBrowserScheme(scheme)) {
    return false;
  }
  if (!ClientHandlesSignIn()) {
    return false;  // 1.2 clients keep Chromium's ERR_UNKNOWN_URL_SCHEME.
  }
  if (url.size() > kMaxExternalURLLength) {
    Blocked("Opening an external application",
            "The " + scheme + ": URL is " + std::to_string(url.size()) + " bytes long.");
    return true;
  }
  Emit(OWLMessageKindExternalProtocol,
       Encoder().String(OWLFieldURL, url).String(OWLFieldOrigin, frame->GetURL().ToString()));
  return true;
}

}  // namespace owl
