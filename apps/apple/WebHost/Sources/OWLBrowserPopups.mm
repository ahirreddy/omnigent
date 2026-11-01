// window.open, target=_blank and modified link clicks open new windowless views that the client
// adopts (PopupCreated), so a popup keeps its JavaScript opener. The popup policy and the
// navigation rules are enforced here, synchronously, in the CEF callbacks. See DESIGN.md,
// "Popups and window.open" and "Agent browser actions".
#include "OWLBrowserClient.hpp"

#include "OWLHost.hpp"

namespace owl {

namespace {

OWLDisposition DispositionFor(cef_window_open_disposition_t disposition) {
  switch (disposition) {
    case CEF_WOD_CURRENT_TAB:
      return OWLDispositionCurrentTab;
    case CEF_WOD_NEW_BACKGROUND_TAB:
      return OWLDispositionBackgroundTab;
    case CEF_WOD_NEW_POPUP:
      return OWLDispositionPopup;
    case CEF_WOD_NEW_WINDOW:
      return OWLDispositionWindow;
    default:
      return OWLDispositionForegroundTab;
  }
}

void ConfigureWindowless(CefWindowInfo* window_info, CefBrowserSettings* settings) {
  window_info->SetAsWindowless(nullptr);
  window_info->shared_texture_enabled = true;
  window_info->runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  settings->windowless_frame_rate = 60;
  settings->background_color = CefColorSetARGB(255, 255, 255, 255);
}

}  // namespace

void BrowserClient::ApplyInitialPolicies(const Decoder& fields) {
  if (fields.U64(OWLFieldPopupPolicy)) {
    HandlePolicyCommand(OWLMessageKindSetPopupPolicy, fields);
  }
  if (fields.String(OWLFieldRules)) {
    HandlePolicyCommand(OWLMessageKindSetNavigationRules, fields);
  }
}

void BrowserClient::HandlePolicyCommand(uint16_t kind, const Decoder& fields) {
  if (kind == OWLMessageKindSetPopupPolicy) {
    const uint64_t policy = fields.U64(OWLFieldPopupPolicy).value_or(0);
    if (policy < OWLPopupPolicyAllow || policy > OWLPopupPolicyBlock) {
      Host::Get().ReportError(view_id_, OWLHostErrorMalformedMessage,
                              "SetPopupPolicy needs a valid PopupPolicy.");
      return;
    }
    popup_policy_ = static_cast<OWLPopupPolicy>(policy);
    return;
  }
  NavigationRules rules;
  std::string error;
  if (!NavigationRules::Parse(fields.String(OWLFieldRules).value_or(""), &rules, &error)) {
    Host::Get().ReportError(view_id_, OWLHostErrorMalformedMessage,
                            "SetNavigationRules: " + error);
    return;
  }
  rules_ = rules;
}

bool BrowserClient::OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, int popup_id,
                                  const CefString& target_url, const CefString& target_frame_name,
                                  WindowOpenDisposition target_disposition, bool user_gesture,
                                  const CefPopupFeatures& popup_features,
                                  CefWindowInfo& window_info, CefRefPtr<CefClient>& client,
                                  CefBrowserSettings& settings, CefRefPtr<CefDictionaryValue>&,
                                  bool*) {
  const std::string url = target_url.ToString();
  if (!ClientHandlesPrompts()) {
    // 1.0 clients cannot adopt views: open in the same view, as before.
    if (!url.empty()) {
      browser->GetMainFrame()->LoadURL(url);
    }
    return true;
  }
  const std::string blocked = rules_.Check(url);
  if (!blocked.empty()) {
    Emit(OWLMessageKindNavigationBlocked,
         Encoder().String(OWLFieldURL, url).String(OWLFieldReason, blocked));
    return true;
  }
  const bool allowed = popup_policy_ == OWLPopupPolicyAllow ||
                       (popup_policy_ == OWLPopupPolicyRequireGesture && user_gesture);
  if (!allowed || Host::Get().IsShuttingDown()) {
    Emit(OWLMessageKindPopupBlocked,
         Encoder()
             .String(OWLFieldURL, url)
             .U64(OWLFieldDisposition, DispositionFor(target_disposition))
             .Bool(OWLFieldUserGesture, user_gesture)
             .String(OWLFieldReason, popup_policy_ == OWLPopupPolicyBlock
                                         ? "Popups are blocked for this view."
                                         : "The page opened a window without a user gesture."));
    return true;
  }
  const uint64_t popup_view =
      OpenPopup(url, target_disposition, user_gesture, target_frame_name.ToString(),
                &popup_features, &window_info, &client, &settings);
  if (popup_view == 0) {
    return true;
  }
  pending_popups_[popup_id] = popup_view;
  return false;
}

uint64_t BrowserClient::OpenPopup(const std::string& url,
                                  cef_window_open_disposition_t disposition, bool user_gesture,
                                  const std::string& frame_name, const CefPopupFeatures* features,
                                  CefWindowInfo* window_info, CefRefPtr<CefClient>* client,
                                  CefBrowserSettings* settings) {
  double width = width_;
  double height = height_;
  if (features != nullptr && features->widthSet && features->width > 0) {
    width = features->width;
  }
  if (features != nullptr && features->heightSet && features->height > 0) {
    height = features->height;
  }
  const uint64_t popup_view = Host::Get().AllocateHostViewID();
  CefRefPtr<BrowserClient> popup(new BrowserClient(popup_view, width, height, scale_, true));
  popup->SetOpener(view_id_);
  popup->popup_policy_ = popup_policy_;
  popup->rules_ = rules_;
  // The client must know the view before its first message (LayerContext).
  Host::Get().Send(OWLMessageKindPopupCreated, 0, popup_view,
                   Encoder()
                       .U64(OWLFieldOpenerID, view_id_)
                       .String(OWLFieldURL, url)
                       .U64(OWLFieldDisposition, DispositionFor(disposition))
                       .Bool(OWLFieldUserGesture, user_gesture)
                       .String(OWLFieldFrameName, frame_name)
                       .Double(OWLFieldWidth, width)
                       .Double(OWLFieldHeight, height));
  std::string error;
  if (!popup->StartPresenter(&error)) {
    Host::Get().ReportError(view_id_, OWLHostErrorPopupFailed, error);
    Host::Get().AdoptView(popup_view, popup);
    Host::Get().AbandonView(popup_view);
    return 0;
  }
  Host::Get().AdoptView(popup_view, popup);
  ConfigureWindowless(window_info, settings);
  *client = popup;
  return popup_view;
}

void BrowserClient::OnBeforePopupAborted(CefRefPtr<CefBrowser>, int popup_id) {
  auto found = pending_popups_.find(popup_id);
  if (found == pending_popups_.end()) {
    return;
  }
  const uint64_t popup_view = found->second;
  pending_popups_.erase(found);
  Host::Get().ReportError(view_id_, OWLHostErrorPopupFailed,
                          "Chromium aborted creating popup view " + std::to_string(popup_view) +
                              ".");
  Host::Get().AbandonView(popup_view);
}

bool BrowserClient::OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
                                     const CefString& target_url,
                                     WindowOpenDisposition target_disposition, bool user_gesture) {
  if (!ClientHandlesPrompts() || target_disposition == CEF_WOD_CURRENT_TAB ||
      Host::Get().IsShuttingDown()) {
    return false;
  }
  // Command- or middle-click on a link: a new view without a JavaScript opener.
  CefWindowInfo window_info;
  CefBrowserSettings settings;
  CefRefPtr<CefClient> client;
  const uint64_t popup_view = OpenPopup(target_url.ToString(), target_disposition, user_gesture,
                                        "", nullptr, &window_info, &client, &settings);
  if (popup_view == 0) {
    return true;
  }
  if (!CefBrowserHost::CreateBrowser(window_info, client, target_url, settings, nullptr,
                                     browser->GetHost()->GetRequestContext())) {
    Host::Get().ReportError(view_id_, OWLHostErrorPopupFailed,
                            "CefBrowserHost::CreateBrowser failed for a new-tab link.");
    Host::Get().AbandonView(popup_view);
  }
  return true;
}

bool BrowserClient::OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request, bool, bool is_redirect) {
  const std::string url = request->GetURL().ToString();
  const std::string reason = rules_.enabled ? rules_.Check(url) : "";
  if (reason.empty()) {
    return HandOffExternalNavigation(frame, url);
  }
  Emit(OWLMessageKindNavigationBlocked,
       Encoder()
           .String(OWLFieldURL, url)
           .String(OWLFieldReason, std::string(frame->IsMain() ? "" : "Subframe: ") +
                                       (is_redirect ? "Redirect: " : "") + reason));
  return true;
}

}  // namespace owl
