// Protocol 1.2 browsing state: favicons, the back/forward list for session restore, audible state
// and per-view mute. See DESIGN.md, "Browsing state (protocol 1.2)".
#include "OWLBrowserClient.hpp"

#include "OWLHost.hpp"
#include "OWLJSON.hpp"
#include <functional>

#include "include/cef_navigation_entry.h"

namespace owl {

namespace {

/// The bridge's isolated world (OWLBrowserInput.mm); page scripts cannot reach it.
constexpr char kMediaWorld[] = "owl-browser-ui";
constexpr char kMediaBinding[] = "owlMediaState";

/// Reports whether any media element in the frame is playing with sound. Chromium does not tell
/// CEF embedders when a page is audible, so the bridge watches media events (they are captured on
/// the document, which isolated worlds share with the page). Web Audio and detached elements are
/// not seen.
constexpr char kMediaSource[] = R"JS((() => {
  if (globalThis.__owlMedia) return;
  const seen = new WeakSet();
  let tracked = [];
  let last = null;
  const audible = (element) => !element.paused && !element.ended && !element.muted &&
    element.volume > 0 && element.readyState >= 2;
  const report = () => {
    tracked = tracked.filter((ref) => ref.deref() !== undefined);
    const elements = new Set(document.querySelectorAll('audio, video'));
    for (const ref of tracked) elements.add(ref.deref());
    let now = false;
    for (const element of elements) {
      if (element && audible(element)) { now = true; break; }
    }
    if (now !== last) {
      last = now;
      globalThis.owlMediaState(JSON.stringify({ audible: now }));
    }
  };
  for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied',
    'loadeddata']) {
    document.addEventListener(type, (event) => {
      const target = event.target;
      if (target instanceof HTMLMediaElement && !seen.has(target)) {
        seen.add(target);
        tracked.push(new WeakRef(target));
      }
      report();
    }, true);
  }
  globalThis.__owlMedia = { report };
})())JS";

/// Collects the back/forward list; CEF calls it once per entry, in order.
class HistoryVisitor : public CefNavigationEntryVisitor {
 public:
  using Done = std::function<void(const std::string&)>;
  explicit HistoryVisitor(Done done) : done_(std::move(done)) {}

  bool Visit(CefRefPtr<CefNavigationEntry> entry, bool current, int index, int total) override {
    CefRefPtr<CefDictionaryValue> item = CefDictionaryValue::Create();
    item->SetString("url", entry->GetURL());
    item->SetString("title", entry->GetTitle());
    entries_->SetDictionary(entries_->GetSize(), item);
    if (current) {
      current_ = index;
    }
    if (index == total - 1) {
      CefRefPtr<CefDictionaryValue> history = CefDictionaryValue::Create();
      history->SetInt("index", current_);
      history->SetList("entries", entries_);
      done_(WriteJSON(history));
    }
    return true;
  }

 private:
  Done done_;
  CefRefPtr<CefListValue> entries_ = CefListValue::Create();
  int current_ = 0;
  IMPLEMENT_REFCOUNTING(HistoryVisitor);
};

}  // namespace

bool BrowserClient::ClientHandlesBrowsing() const {
  return Host::Get().config().client_minor >= OWL_PROTOCOL_MINOR_BROWSING;
}

void BrowserClient::InstallMediaBridge() {
  CefRefPtr<CefDictionaryValue> binding = CefDictionaryValue::Create();
  binding->SetString("name", kMediaBinding);
  binding->SetString("executionContextName", kMediaWorld);
  RunInternalDevTools("Runtime.addBinding", binding);
  CefRefPtr<CefDictionaryValue> script = CefDictionaryValue::Create();
  script->SetString("source", kMediaSource);
  script->SetString("worldName", kMediaWorld);
  script->SetBool("runImmediately", true);
  RunInternalDevTools("Page.addScriptToEvaluateOnNewDocument", script);
}

void BrowserClient::SetAudioMuted(bool muted) {
  if (!browser_) {
    return;
  }
  browser_->GetHost()->SetAudioMuted(muted);
  muted_ = muted;
  Emit(OWLMessageKindAudioStateChanged,
       Encoder().Bool(OWLFieldAudible, audible_).Bool(OWLFieldMuted, muted_));
}

void BrowserClient::EmitAudioState() {
  bool audible = false;
  for (const auto& entry : audible_contexts_) {
    audible = audible || entry.second;
  }
  if (audible == audible_) {
    return;
  }
  audible_ = audible;
  Emit(OWLMessageKindAudioStateChanged,
       Encoder().Bool(OWLFieldAudible, audible_).Bool(OWLFieldMuted, muted_));
}

bool BrowserClient::HandleMediaEvent(const std::string& method,
                                     CefRefPtr<CefDictionaryValue> event) {
  if (!ClientHandlesBrowsing()) {
    return false;
  }
  if (method == "Runtime.executionContextsCleared") {
    audible_contexts_.clear();
    EmitAudioState();
    return true;
  }
  if (method == "Runtime.executionContextDestroyed") {
    audible_contexts_.erase(event->GetInt("executionContextId"));
    EmitAudioState();
    return true;
  }
  if (event->GetString("name") != kMediaBinding) {
    return false;
  }
  CefRefPtr<CefDictionaryValue> payload = ParseObject(event->GetString("payload").ToString());
  if (!payload) {
    Host::Get().ReportError(view_id_, OWLHostErrorMalformedMessage,
                            "The media bridge sent a malformed payload.");
    return true;
  }
  audible_contexts_[event->GetInt("executionContextId")] = payload->GetBool("audible");
  EmitAudioState();
  return true;
}

void BrowserClient::EmitNavigationHistory() {
  if (!browser_ || !ClientHandlesBrowsing()) {
    return;
  }
  CefRefPtr<BrowserClient> self(this);
  browser_->GetHost()->GetNavigationEntries(
      new HistoryVisitor([self](const std::string& json) {
        if (json == self->last_history_json_) {
          return;
        }
        self->last_history_json_ = json;
        self->Emit(OWLMessageKindNavigationHistory, Encoder().String(OWLFieldJSON, json));
      }),
      false);
}

void BrowserClient::OnFaviconURLChange(CefRefPtr<CefBrowser>,
                                       const std::vector<CefString>& icon_urls) {
  if (!ClientHandlesBrowsing()) {
    return;
  }
  std::vector<std::string> urls;
  for (const CefString& url : icon_urls) {
    urls.push_back(url.ToString());
  }
  Emit(OWLMessageKindFaviconURLChanged, Encoder().String(OWLFieldJSON, WriteJSON(StringList(urls))));
}

}  // namespace owl
