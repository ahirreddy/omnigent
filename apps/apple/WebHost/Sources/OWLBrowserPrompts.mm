// Browser UI the page asks for (JavaScript dialogs, permission prompts, file choosers, downloads,
// context menus, HTTP auth and certificate errors), projected to the client as 1.1 requests that
// the client answers by PromptID. 1.0 clients keep the old behavior: every request is denied and
// reported as FeatureBlocked. See DESIGN.md, "Browser UI over the channel".
#include "OWLBrowserClient.hpp"

#include "OWLHost.hpp"
#include "OWLJSON.hpp"
#include "include/base/cef_callback.h"
#include "include/cef_menu_model.h"
#include "include/cef_ssl_info.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"

namespace owl {

namespace {

const char* DialogName(cef_jsdialog_type_t type) {
  switch (type) {
    case JSDIALOGTYPE_ALERT:
      return "alert()";
    case JSDIALOGTYPE_CONFIRM:
      return "confirm()";
    case JSDIALOGTYPE_PROMPT:
      return "prompt()";
    case JSDIALOGTYPE_NUM_VALUES:
      break;
  }
  return "JavaScript dialog";
}

OWLDialogKind DialogKindFor(cef_jsdialog_type_t type) {
  switch (type) {
    case JSDIALOGTYPE_CONFIRM:
      return OWLDialogKindConfirm;
    case JSDIALOGTYPE_PROMPT:
      return OWLDialogKindPrompt;
    case JSDIALOGTYPE_ALERT:
    case JSDIALOGTYPE_NUM_VALUES:
      break;
  }
  return OWLDialogKindAlert;
}

uint64_t PermissionsFromPrompt(uint32_t requested) {
  uint64_t result = 0;
  uint32_t known = 0;
  auto map = [&](uint32_t cef, OWLPermission owl) {
    known |= cef;
    if ((requested & cef) != 0) {
      result |= owl;
    }
  };
  map(CEF_PERMISSION_TYPE_CAMERA_STREAM | CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM,
      OWLPermissionCamera);
  map(CEF_PERMISSION_TYPE_MIC_STREAM, OWLPermissionMicrophone);
  map(CEF_PERMISSION_TYPE_GEOLOCATION, OWLPermissionGeolocation);
  map(CEF_PERMISSION_TYPE_NOTIFICATIONS, OWLPermissionNotifications);
  map(CEF_PERMISSION_TYPE_CLIPBOARD, OWLPermissionClipboard);
  map(CEF_PERMISSION_TYPE_MIDI_SYSEX, OWLPermissionMIDI);
  if ((requested & ~known) != 0) {
    result |= OWLPermissionOther;
  }
  return result;
}

uint64_t PermissionsFromMedia(uint32_t requested) {
  uint64_t result = 0;
  if ((requested & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) != 0) {
    result |= OWLPermissionCamera;
  }
  if ((requested & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) != 0) {
    result |= OWLPermissionMicrophone;
  }
  if ((requested & (CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE |
                    CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE)) != 0) {
    result |= OWLPermissionScreenCapture;
  }
  return result;
}

const char* CertificateErrorName(cef_errorcode_t code) {
  switch (code) {
    case ERR_CERT_COMMON_NAME_INVALID:
      return "The certificate is not valid for this host name.";
    case ERR_CERT_DATE_INVALID:
      return "The certificate has expired or is not yet valid.";
    case ERR_CERT_AUTHORITY_INVALID:
      return "The certificate is not issued by a trusted authority.";
    case ERR_CERT_REVOKED:
      return "The certificate has been revoked.";
    case ERR_CERT_WEAK_SIGNATURE_ALGORITHM:
    case ERR_CERT_WEAK_KEY:
      return "The certificate uses weak cryptography.";
    default:
      return "The certificate is not valid.";
  }
}

/// Menu labels use '&' for mnemonics, and '&&' for a literal ampersand.
std::string StripMnemonics(const std::string& label) {
  std::string result;
  for (size_t index = 0; index < label.size(); ++index) {
    if (label[index] == '&') {
      if (index + 1 < label.size() && label[index + 1] == '&') {
        result.push_back('&');
        ++index;
      }
      continue;
    }
    result.push_back(label[index]);
  }
  return result;
}

const char* MenuItemKind(cef_menu_item_type_t type) {
  switch (type) {
    case MENUITEMTYPE_CHECK:
      return "check";
    case MENUITEMTYPE_RADIO:
      return "radio";
    case MENUITEMTYPE_SEPARATOR:
      return "separator";
    case MENUITEMTYPE_SUBMENU:
      return "submenu";
    default:
      return "command";
  }
}

CefRefPtr<CefListValue> SerializeMenu(CefRefPtr<CefMenuModel> model, int depth) {
  CefRefPtr<CefListValue> items = CefListValue::Create();
  for (size_t index = 0; index < model->GetCount(); ++index) {
    CefRefPtr<CefDictionaryValue> item = CefDictionaryValue::Create();
    const cef_menu_item_type_t type = model->GetTypeAt(index);
    item->SetInt("id", model->GetCommandIdAt(index));
    item->SetString("kind", MenuItemKind(type));
    item->SetString("label", StripMnemonics(model->GetLabelAt(index).ToString()));
    item->SetBool("enabled", model->IsEnabledAt(index));
    item->SetBool("checked", model->IsCheckedAt(index));
    CefRefPtr<CefMenuModel> submenu = model->GetSubMenuAt(index);
    if (type == MENUITEMTYPE_SUBMENU && submenu && depth < 4) {
      item->SetList("items", SerializeMenu(submenu, depth + 1));
    }
    items->SetDictionary(items->GetSize(), item);
  }
  return items;
}

/// Removes items that would open UI in the host process, then tidies separators.
void PruneMenu(CefRefPtr<CefMenuModel> model) {
  model->Remove(MENU_ID_PRINT);
  model->Remove(MENU_ID_VIEW_SOURCE);
  bool previous_separator = true;
  for (size_t index = 0; index < model->GetCount();) {
    const bool separator = model->GetTypeAt(index) == MENUITEMTYPE_SEPARATOR;
    if (separator && previous_separator) {
      model->RemoveAt(index);
      continue;
    }
    previous_separator = separator;
    ++index;
  }
  while (model->GetCount() > 0 &&
         model->GetTypeAt(model->GetCount() - 1) == MENUITEMTYPE_SEPARATOR) {
    model->RemoveAt(model->GetCount() - 1);
  }
}

double SecondsSinceEpoch(const CefBaseTime& time) {
  cef_time_t exploded{};
  if (cef_time_from_basetime(time, &exploded) == 0) {
    return 0;
  }
  return CefTime(exploded).GetDoubleT();
}

}  // namespace

bool BrowserClient::ClientHandlesPrompts() const {
  return Host::Get().config().client_minor >= OWL_PROTOCOL_MINOR_PROMPTS;
}

void BrowserClient::PromptCancelled(uint64_t prompt_id, const std::string& reason) {
  Emit(OWLMessageKindPromptCancelled,
       Encoder().U64(OWLFieldPromptID, prompt_id).String(OWLFieldReason, reason));
}

void BrowserClient::UnknownPrompt(uint16_t kind, uint64_t prompt_id) {
  Host::Get().ReportError(view_id_, OWLHostErrorUnknownPrompt,
                          "Reply " + std::to_string(kind) + " names prompt " +
                              std::to_string(prompt_id) +
                              ", which is not pending (answered, cancelled or never sent).");
}

void BrowserClient::CancelPendingPrompts(const std::string& reason) {
  std::vector<uint64_t> cancelled;
  for (const auto& entry : dialogs_) {
    cancelled.push_back(entry.first);
  }
  for (const auto& entry : permission_prompts_) {
    entry.second->Continue(CEF_PERMISSION_RESULT_DISMISS);
    cancelled.push_back(entry.first);
  }
  for (const auto& entry : media_requests_) {
    entry.second.callback->Cancel();
    cancelled.push_back(entry.first);
  }
  for (const auto& entry : file_dialogs_) {
    entry.second->Cancel();
    cancelled.push_back(entry.first);
  }
  for (const auto& entry : context_menus_) {
    entry.second->Cancel();
    cancelled.push_back(entry.first);
  }
  for (const auto& entry : auth_requests_) {
    entry.second->Cancel();
    cancelled.push_back(entry.first);
  }
  for (const auto& entry : certificate_errors_) {
    entry.second->Cancel();
    cancelled.push_back(entry.first);
  }
  for (const auto& entry : download_requests_) {
    cancelled.push_back(entry.first);  // Releasing the callback cancels the download.
  }
  for (const auto& entry : color_requests_) {
    cancelled.push_back(entry.first);
  }
  color_requests_.clear();
  dialogs_.clear();
  permission_prompts_.clear();
  cef_permission_prompts_.clear();
  media_requests_.clear();
  file_dialogs_.clear();
  context_menus_.clear();
  auth_requests_.clear();
  certificate_errors_.clear();
  download_requests_.clear();
  pending_popups_.clear();
  for (uint64_t prompt_id : cancelled) {
    PromptCancelled(prompt_id, reason);
  }
}

bool BrowserClient::IsBrowserUICommand(uint16_t kind) {
  return kind >= OWLMessageKindSetPopupPolicy && kind <= OWLMessageKindColorReply;
}

void BrowserClient::HandleBrowserUICommand(uint16_t kind, const Decoder& fields) {
  switch (kind) {
    case OWLMessageKindSetPopupPolicy:
    case OWLMessageKindSetNavigationRules:
      HandlePolicyCommand(kind, fields);
      return;
    case OWLMessageKindDialogReply:
      HandleDialogReply(fields);
      return;
    case OWLMessageKindPermissionReply:
      HandlePermissionReply(fields);
      return;
    case OWLMessageKindFileChooserReply:
      HandleFileChooserReply(fields);
      return;
    case OWLMessageKindDownloadReply:
      HandleDownloadReply(fields);
      return;
    case OWLMessageKindDownloadControl:
      HandleDownloadControl(fields);
      return;
    case OWLMessageKindContextMenuReply:
      HandleContextMenuReply(fields);
      return;
    case OWLMessageKindAuthReply:
      HandleAuthReply(fields);
      return;
    case OWLMessageKindCertificateReply:
      HandleCertificateReply(fields);
      return;
    case OWLMessageKindColorReply:
      HandleColorReply(fields);
      return;
    default:
      break;
  }
  if (kind >= OWLMessageKindImeSetComposition && kind <= OWLMessageKindImeCancelComposition) {
    HandleImeCommand(kind, fields);
  } else if (kind >= OWLMessageKindDragEnter && kind <= OWLMessageKindDragSourceEnded) {
    HandleDragCommand(kind, fields);
  } else {
    Host::Get().ReportError(view_id_, OWLHostErrorUnknownMessage,
                            "Unknown view message " + std::to_string(kind) + ".");
  }
}

// MARK: JavaScript dialogs

bool BrowserClient::OnJSDialog(CefRefPtr<CefBrowser>, const CefString& origin_url,
                               JSDialogType dialog_type, const CefString& message_text,
                               const CefString& default_prompt_text,
                               CefRefPtr<CefJSDialogCallback> callback, bool& suppress_message) {
  if (!ClientHandlesPrompts()) {
    suppress_message = true;
    Blocked(DialogName(dialog_type), origin_url.ToString() + ": " + message_text.ToString());
    return false;
  }
  const uint64_t prompt_id = NextPromptID();
  dialogs_[prompt_id] = callback;
  Encoder fields;
  fields.U64(OWLFieldPromptID, prompt_id)
      .U64(OWLFieldDialogKind, DialogKindFor(dialog_type))
      .String(OWLFieldOrigin, origin_url.ToString())
      .String(OWLFieldMessage, message_text.ToString());
  if (dialog_type == JSDIALOGTYPE_PROMPT) {
    fields.String(OWLFieldDefaultText, default_prompt_text.ToString());
  }
  Emit(OWLMessageKindJSDialog, fields);
  return true;
}

bool BrowserClient::OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                                         const CefString& message_text, bool is_reload,
                                         CefRefPtr<CefJSDialogCallback> callback) {
  if (!ClientHandlesPrompts()) {
    callback->Continue(true, CefString());
    return true;
  }
  const uint64_t prompt_id = NextPromptID();
  dialogs_[prompt_id] = callback;
  Emit(OWLMessageKindJSDialog,
       Encoder()
           .U64(OWLFieldPromptID, prompt_id)
           .U64(OWLFieldDialogKind, OWLDialogKindBeforeUnload)
           .String(OWLFieldOrigin, browser->GetMainFrame()->GetURL().ToString())
           .String(OWLFieldMessage, message_text.ToString())
           .Bool(OWLFieldIsReload, is_reload));
  return true;
}

void BrowserClient::OnResetDialogState(CefRefPtr<CefBrowser>) {
  std::vector<uint64_t> cancelled;
  for (const auto& entry : dialogs_) {
    cancelled.push_back(entry.first);
  }
  dialogs_.clear();
  for (uint64_t prompt_id : cancelled) {
    PromptCancelled(prompt_id, "The page navigated or was closed.");
  }
}

void BrowserClient::HandleDialogReply(const Decoder& fields) {
  const uint64_t prompt_id = fields.U64(OWLFieldPromptID).value_or(0);
  auto found = dialogs_.find(prompt_id);
  if (found == dialogs_.end()) {
    UnknownPrompt(OWLMessageKindDialogReply, prompt_id);
    return;
  }
  CefRefPtr<CefJSDialogCallback> callback = found->second;
  dialogs_.erase(found);
  callback->Continue(fields.Bool(OWLFieldAccepted).value_or(false),
                     fields.String(OWLFieldText).value_or(""));
}

// MARK: Permissions

bool BrowserClient::OnRequestMediaAccessPermission(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                                   const CefString& requesting_origin,
                                                   uint32_t requested_permissions,
                                                   CefRefPtr<CefMediaAccessCallback> callback) {
  if (!ClientHandlesPrompts()) {
    callback->Cancel();
    Blocked("Camera and microphone access", requesting_origin.ToString());
    return true;
  }
  const uint64_t prompt_id = NextPromptID();
  media_requests_[prompt_id] = PendingMedia{callback, requested_permissions};
  Emit(OWLMessageKindPermissionRequest,
       Encoder()
           .U64(OWLFieldPromptID, prompt_id)
           .String(OWLFieldOrigin, requesting_origin.ToString())
           .U64(OWLFieldPermissions, PermissionsFromMedia(requested_permissions)));
  return true;
}

bool BrowserClient::OnShowPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t cef_prompt_id,
                                           const CefString& requesting_origin,
                                           uint32_t requested_permissions,
                                           CefRefPtr<CefPermissionPromptCallback> callback) {
  if (!ClientHandlesPrompts()) {
    callback->Continue(CEF_PERMISSION_RESULT_DENY);
    Blocked("Permission prompt", requesting_origin.ToString() + " requested permissions 0x" +
                                     std::to_string(requested_permissions));
    return true;
  }
  const uint64_t prompt_id = NextPromptID();
  permission_prompts_[prompt_id] = callback;
  cef_permission_prompts_[cef_prompt_id] = prompt_id;
  Emit(OWLMessageKindPermissionRequest,
       Encoder()
           .U64(OWLFieldPromptID, prompt_id)
           .String(OWLFieldOrigin, requesting_origin.ToString())
           .U64(OWLFieldPermissions, PermissionsFromPrompt(requested_permissions)));
  return true;
}

void BrowserClient::OnDismissPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t cef_prompt_id,
                                              cef_permission_request_result_t) {
  auto mapped = cef_permission_prompts_.find(cef_prompt_id);
  if (mapped == cef_permission_prompts_.end()) {
    return;
  }
  const uint64_t prompt_id = mapped->second;
  cef_permission_prompts_.erase(mapped);
  if (permission_prompts_.erase(prompt_id) != 0) {
    PromptCancelled(prompt_id, "Chromium dismissed the permission request.");
  }
}

void BrowserClient::HandlePermissionReply(const Decoder& fields) {
  const uint64_t prompt_id = fields.U64(OWLFieldPromptID).value_or(0);
  const uint64_t result = fields.U64(OWLFieldPermissionResult).value_or(OWLPermissionResultDeny);
  if (auto prompt = permission_prompts_.find(prompt_id); prompt != permission_prompts_.end()) {
    CefRefPtr<CefPermissionPromptCallback> callback = prompt->second;
    permission_prompts_.erase(prompt);
    for (auto it = cef_permission_prompts_.begin(); it != cef_permission_prompts_.end(); ++it) {
      if (it->second == prompt_id) {
        cef_permission_prompts_.erase(it);
        break;
      }
    }
    callback->Continue(result == OWLPermissionResultAllow   ? CEF_PERMISSION_RESULT_ACCEPT
                       : result == OWLPermissionResultDeny ? CEF_PERMISSION_RESULT_DENY
                                                           : CEF_PERMISSION_RESULT_DISMISS);
    return;
  }
  if (auto media = media_requests_.find(prompt_id); media != media_requests_.end()) {
    PendingMedia pending = media->second;
    media_requests_.erase(media);
    // getUserMedia needs every requested device or none.
    if (result == OWLPermissionResultAllow) {
      pending.callback->Continue(pending.requested);
    } else {
      pending.callback->Cancel();
    }
    return;
  }
  UnknownPrompt(OWLMessageKindPermissionReply, prompt_id);
}

// MARK: File chooser

bool BrowserClient::OnFileDialog(CefRefPtr<CefBrowser>, FileDialogMode mode,
                                 const CefString& title, const CefString& default_file_path,
                                 const std::vector<CefString>& accept_filters,
                                 const std::vector<CefString>& accept_extensions,
                                 const std::vector<CefString>& accept_descriptions,
                                 CefRefPtr<CefFileDialogCallback> callback) {
  if (!ClientHandlesPrompts()) {
    callback->Cancel();
    Blocked("File chooser", title.ToString());
    return true;
  }
  CefRefPtr<CefListValue> accept = CefListValue::Create();
  for (size_t index = 0; index < accept_filters.size(); ++index) {
    CefRefPtr<CefDictionaryValue> entry = CefDictionaryValue::Create();
    entry->SetString("filter", accept_filters[index]);
    std::vector<std::string> extensions;
    const std::string joined =
        index < accept_extensions.size() ? accept_extensions[index].ToString() : "";
    size_t start = 0;
    while (start < joined.size()) {
      const size_t end = joined.find(';', start);
      std::string extension = joined.substr(start, end == std::string::npos ? end : end - start);
      if (!extension.empty() && extension[0] == '.') {
        extension.erase(0, 1);
      }
      if (!extension.empty()) {
        extensions.push_back(extension);
      }
      if (end == std::string::npos) {
        break;
      }
      start = end + 1;
    }
    entry->SetList("extensions", StringList(extensions));
    entry->SetString("description",
                     index < accept_descriptions.size() ? accept_descriptions[index] : "");
    accept->SetDictionary(index, entry);
  }
  const uint64_t prompt_id = NextPromptID();
  file_dialogs_[prompt_id] = callback;
  Emit(OWLMessageKindFileChooser, Encoder()
                                      .U64(OWLFieldPromptID, prompt_id)
                                      .U64(OWLFieldFileChooserMode, static_cast<uint64_t>(mode))
                                      .String(OWLFieldTitle, title.ToString())
                                      .String(OWLFieldDefaultText, default_file_path.ToString())
                                      .String(OWLFieldAcceptTypes, WriteJSON(accept)));
  return true;
}

void BrowserClient::HandleFileChooserReply(const Decoder& fields) {
  const uint64_t prompt_id = fields.U64(OWLFieldPromptID).value_or(0);
  auto found = file_dialogs_.find(prompt_id);
  if (found == file_dialogs_.end()) {
    UnknownPrompt(OWLMessageKindFileChooserReply, prompt_id);
    return;
  }
  CefRefPtr<CefFileDialogCallback> callback = found->second;
  file_dialogs_.erase(found);
  std::vector<std::string> paths;
  if (!fields.Bool(OWLFieldAccepted).value_or(false)) {
    callback->Cancel();
    return;
  }
  if (!ParseStringList(fields.String(OWLFieldPaths).value_or(""), &paths)) {
    callback->Cancel();
    Host::Get().ReportError(view_id_, OWLHostErrorMalformedMessage,
                            "FileChooserReply Paths must be a JSON array of strings.");
    return;
  }
  callback->Continue(std::vector<CefString>(paths.begin(), paths.end()));
}

// MARK: Context menus

void BrowserClient::OnBeforeContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                        CefRefPtr<CefContextMenuParams>,
                                        CefRefPtr<CefMenuModel> model) {
  if (!ClientHandlesPrompts()) {
    // A native menu would open in the host process; 1.0 clients cannot show one.
    model->Clear();
    return;
  }
  PruneMenu(model);
}

bool BrowserClient::RunContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                   CefRefPtr<CefContextMenuParams> params,
                                   CefRefPtr<CefMenuModel> model,
                                   CefRefPtr<CefRunContextMenuCallback> callback) {
  if (!ClientHandlesPrompts() || last_pointer_origin_ == OWLInputOriginAgent) {
    callback->Cancel();
    if (last_pointer_origin_ == OWLInputOriginAgent) {
      Blocked("Context menu", "Agent input never opens browser UI.");
    }
    return true;
  }
  CefRefPtr<CefDictionaryValue> context = CefDictionaryValue::Create();
  context->SetInt("x", params->GetXCoord());
  context->SetInt("y", params->GetYCoord());
  context->SetString("linkURL", params->GetLinkUrl());
  context->SetString("sourceURL", params->GetSourceUrl());
  context->SetString("pageURL", params->GetPageUrl());
  context->SetString("frameURL", params->GetFrameUrl());
  context->SetString("selectionText", params->GetSelectionText());
  context->SetBool("isEditable", params->IsEditable());
  context->SetInt("mediaType", static_cast<int>(params->GetMediaType()));
  context->SetInt("editFlags", static_cast<int>(params->GetEditStateFlags()));
  const uint64_t prompt_id = NextPromptID();
  context_menus_[prompt_id] = callback;
  Emit(OWLMessageKindContextMenu,
       Encoder()
           .U64(OWLFieldPromptID, prompt_id)
           .Double(OWLFieldX, params->GetXCoord())
           .Double(OWLFieldY, params->GetYCoord())
           .String(OWLFieldMenuItems, WriteJSON(SerializeMenu(model, 0)))
           .String(OWLFieldMenuParams, WriteJSON(context)));
  return true;
}

void BrowserClient::HandleContextMenuReply(const Decoder& fields) {
  const uint64_t prompt_id = fields.U64(OWLFieldPromptID).value_or(0);
  auto found = context_menus_.find(prompt_id);
  if (found == context_menus_.end()) {
    UnknownPrompt(OWLMessageKindContextMenuReply, prompt_id);
    return;
  }
  CefRefPtr<CefRunContextMenuCallback> callback = found->second;
  context_menus_.erase(found);
  const int64_t command = fields.I64(OWLFieldCommandID).value_or(-1);
  if (command < 0) {
    callback->Cancel();
  } else {
    callback->Continue(static_cast<int>(command), EVENTFLAG_NONE);
  }
}

// MARK: HTTP authentication

bool BrowserClient::GetAuthCredentials(CefRefPtr<CefBrowser>, const CefString& origin_url,
                                       bool is_proxy, const CefString& host, int port,
                                       const CefString& realm, const CefString& scheme,
                                       CefRefPtr<CefAuthCallback> callback) {
  // Called on the IO thread; prompts live on the UI thread.
  CefPostTask(TID_UI, base::BindOnce(&BrowserClient::RequestAuth, CefRefPtr<BrowserClient>(this),
                                     origin_url.ToString(), is_proxy, host.ToString(), port,
                                     realm.ToString(), scheme.ToString(), callback));
  return true;
}

void BrowserClient::RequestAuth(std::string origin, bool is_proxy, std::string host, int port,
                                std::string realm, std::string scheme,
                                CefRefPtr<CefAuthCallback> callback) {
  if (!ClientHandlesPrompts() || close_requested_) {
    callback->Cancel();
    Blocked("HTTP authentication", host + ":" + std::to_string(port) + " realm " + realm);
    return;
  }
  const uint64_t prompt_id = NextPromptID();
  auth_requests_[prompt_id] = callback;
  Emit(OWLMessageKindAuthRequest, Encoder()
                                      .U64(OWLFieldPromptID, prompt_id)
                                      .String(OWLFieldOrigin, origin)
                                      .String(OWLFieldHost, host)
                                      .U64(OWLFieldPort, static_cast<uint64_t>(port))
                                      .String(OWLFieldRealm, realm)
                                      .String(OWLFieldScheme, scheme)
                                      .Bool(OWLFieldIsProxy, is_proxy));
}

void BrowserClient::HandleAuthReply(const Decoder& fields) {
  const uint64_t prompt_id = fields.U64(OWLFieldPromptID).value_or(0);
  auto found = auth_requests_.find(prompt_id);
  if (found == auth_requests_.end()) {
    UnknownPrompt(OWLMessageKindAuthReply, prompt_id);
    return;
  }
  CefRefPtr<CefAuthCallback> callback = found->second;
  auth_requests_.erase(found);
  if (fields.Bool(OWLFieldAccepted).value_or(false)) {
    callback->Continue(fields.String(OWLFieldUsername).value_or(""),
                       fields.String(OWLFieldPassword).value_or(""));
  } else {
    callback->Cancel();
  }
}

// MARK: Certificate errors

bool BrowserClient::OnCertificateError(CefRefPtr<CefBrowser>, cef_errorcode_t cert_error,
                                       const CefString& request_url,
                                       CefRefPtr<CefSSLInfo> ssl_info,
                                       CefRefPtr<CefCallback> callback) {
  if (!ClientHandlesPrompts()) {
    return false;
  }
  // Chromium passes no callback when the error cannot be overridden (for example HSTS).
  const bool overridable = callback != nullptr;
  const uint64_t prompt_id = overridable ? NextPromptID() : 0;
  Encoder fields;
  fields.U64(OWLFieldPromptID, prompt_id)
      .String(OWLFieldURL, request_url.ToString())
      .I64(OWLFieldErrorCode, cert_error)
      .String(OWLFieldMessage, CertificateErrorName(cert_error))
      .Bool(OWLFieldOverridable, overridable);
  CefRefPtr<CefX509Certificate> certificate = ssl_info ? ssl_info->GetX509Certificate() : nullptr;
  if (certificate) {
    if (CefRefPtr<CefX509CertPrincipal> subject = certificate->GetSubject()) {
      fields.String(OWLFieldCertSubject, subject->GetDisplayName().ToString());
    }
    if (CefRefPtr<CefX509CertPrincipal> issuer = certificate->GetIssuer()) {
      fields.String(OWLFieldCertIssuer, issuer->GetDisplayName().ToString());
    }
    fields.Double(OWLFieldCertValidStart, SecondsSinceEpoch(certificate->GetValidStart()))
        .Double(OWLFieldCertValidExpiry, SecondsSinceEpoch(certificate->GetValidExpiry()));
  }
  Emit(OWLMessageKindCertificateError, fields);
  if (!overridable) {
    return false;
  }
  certificate_errors_[prompt_id] = callback;
  return true;
}

void BrowserClient::HandleCertificateReply(const Decoder& fields) {
  const uint64_t prompt_id = fields.U64(OWLFieldPromptID).value_or(0);
  auto found = certificate_errors_.find(prompt_id);
  if (found == certificate_errors_.end()) {
    UnknownPrompt(OWLMessageKindCertificateReply, prompt_id);
    return;
  }
  CefRefPtr<CefCallback> callback = found->second;
  certificate_errors_.erase(found);
  if (fields.Bool(OWLFieldAccepted).value_or(false)) {
    callback->Continue();
  } else {
    callback->Cancel();
  }
}

// MARK: Downloads

bool BrowserClient::CanDownload(CefRefPtr<CefBrowser>, const CefString& url, const CefString&) {
  if (!ClientHandlesPrompts()) {
    Emit(OWLMessageKindDownloadBlocked, Encoder().String(OWLFieldURL, url.ToString()));
    return false;
  }
  return true;
}

bool BrowserClient::OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
                                     const CefString& suggested_name,
                                     CefRefPtr<CefBeforeDownloadCallback> callback) {
  if (!ClientHandlesPrompts()) {
    return false;
  }
  const uint64_t prompt_id = NextPromptID();
  download_requests_[prompt_id] = callback;
  Emit(OWLMessageKindDownloadRequest,
       Encoder()
           .U64(OWLFieldPromptID, prompt_id)
           .U64(OWLFieldDownloadID, item->GetId())
           .String(OWLFieldURL, item->GetURL().ToString())
           .String(OWLFieldSuggestedName, suggested_name.ToString())
           .String(OWLFieldMimeType, item->GetMimeType().ToString())
           .I64(OWLFieldTotalBytes, item->GetTotalBytes()));
  return true;
}

void BrowserClient::OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
                                      CefRefPtr<CefDownloadItemCallback> callback) {
  if (!ClientHandlesPrompts()) {
    return;
  }
  OWLDownloadState state = OWLDownloadStateInProgress;
  if (item->IsComplete()) {
    state = OWLDownloadStateComplete;
  } else if (item->IsCanceled()) {
    state = OWLDownloadStateCancelled;
  } else if (item->IsInterrupted()) {
    state = OWLDownloadStateInterrupted;
  } else if (item->IsPaused()) {
    state = OWLDownloadStatePaused;
  }
  const uint32_t download_id = item->GetId();
  if (state == OWLDownloadStateInProgress || state == OWLDownloadStatePaused) {
    download_controls_[download_id] = callback;
  } else {
    download_controls_.erase(download_id);
  }
  Emit(OWLMessageKindDownloadUpdated, Encoder()
                                          .U64(OWLFieldDownloadID, download_id)
                                          .String(OWLFieldURL, item->GetURL().ToString())
                                          .I64(OWLFieldReceivedBytes, item->GetReceivedBytes())
                                          .I64(OWLFieldTotalBytes, item->GetTotalBytes())
                                          .U64(OWLFieldDownloadState, state)
                                          .String(OWLFieldPath, item->GetFullPath().ToString()));
}

void BrowserClient::HandleDownloadReply(const Decoder& fields) {
  const uint64_t prompt_id = fields.U64(OWLFieldPromptID).value_or(0);
  auto found = download_requests_.find(prompt_id);
  if (found == download_requests_.end()) {
    UnknownPrompt(OWLMessageKindDownloadReply, prompt_id);
    return;
  }
  CefRefPtr<CefBeforeDownloadCallback> callback = found->second;
  download_requests_.erase(found);
  auto path = fields.String(OWLFieldPath);
  if (fields.Bool(OWLFieldAccepted).value_or(false) && path && !path->empty()) {
    callback->Continue(*path, false);
  }
  // Otherwise the callback is released unexecuted, which cancels the download.
}

void BrowserClient::HandleDownloadControl(const Decoder& fields) {
  const uint32_t download_id = static_cast<uint32_t>(fields.U64(OWLFieldDownloadID).value_or(0));
  auto found = download_controls_.find(download_id);
  if (found == download_controls_.end()) {
    Host::Get().ReportError(view_id_, OWLHostErrorUnknownPrompt,
                            "Download " + std::to_string(download_id) + " is not in progress.");
    return;
  }
  switch (fields.U64(OWLFieldDownloadCommand).value_or(0)) {
    case OWLDownloadCommandCancel:
      found->second->Cancel();
      break;
    case OWLDownloadCommandPause:
      found->second->Pause();
      break;
    case OWLDownloadCommandResume:
      found->second->Resume();
      break;
    default:
      Host::Get().ReportError(view_id_, OWLHostErrorMalformedMessage,
                              "DownloadControl needs a valid DownloadCommand.");
      break;
  }
}

}  // namespace owl
