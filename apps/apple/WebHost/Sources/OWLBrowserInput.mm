// IME composition, drag and drop in both directions, and the isolated-world bridge that projects
// `<input type=color>` to the client. See DESIGN.md, "Input".
#include "OWLBrowserClient.hpp"

#import <Foundation/Foundation.h>

#include <unistd.h>

#include <regex>

#include "OWLHost.hpp"
#include "OWLJSON.hpp"
#include "include/cef_drag_data.h"
#include "include/cef_image.h"
#include "include/cef_stream.h"

namespace owl {

namespace {

/// The isolated world the bridge runs in. Page scripts cannot see it or call its binding.
constexpr char kBridgeWorld[] = "owl-browser-ui";
constexpr char kColorBinding[] = "owlColorChooser";

/// Intercepts activation of color inputs (click, or keyboard activation, which dispatches a
/// click) so Chromium does not open its own color panel in the host process.
constexpr char kBridgeSource[] = R"JS((() => {
  if (globalThis.__owlBridge) return;
  const inputs = new Map();
  let next = 0;
  globalThis.__owlBridge = {
    setColor(id, value) {
      const input = inputs.get(id)?.deref();
      inputs.delete(id);
      if (!input) return false;
      input.value = value;
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
      return true;
    },
  };
  document.addEventListener('click', (event) => {
    const target = event.composedPath()[0];
    if (!(target instanceof HTMLInputElement) || target.type !== 'color' || target.disabled) {
      return;
    }
    event.preventDefault();
    const id = ++next;
    inputs.set(id, new WeakRef(target));
    globalThis.owlColorChooser(JSON.stringify({ id, value: target.value }));
  }, true);
})())JS";

CefMouseEvent MouseEventFrom(const Decoder& fields) {
  CefMouseEvent event;
  event.x = static_cast<int>(fields.Double(OWLFieldX).value_or(0));
  event.y = static_cast<int>(fields.Double(OWLFieldY).value_or(0));
  event.modifiers = static_cast<uint32_t>(fields.U64(OWLFieldModifiers).value_or(0));
  return event;
}

CefRange RangeFrom(const Decoder& fields, OWLField start, OWLField end) {
  auto lower = fields.I64(start);
  auto upper = fields.I64(end);
  if (!lower || !upper || *lower < 0 || *upper < *lower) {
    return CefRange::InvalidRange();
  }
  return CefRange(static_cast<uint32_t>(*lower), static_cast<uint32_t>(*upper));
}

std::string Basename(const std::string& path) {
  const size_t slash = path.find_last_of('/');
  return slash == std::string::npos ? path : path.substr(slash + 1);
}

/// Fills a writable CefDragData from the DragData JSON (owl_protocol.h).
bool DragDataFromJSON(const std::string& json, CefRefPtr<CefDragData> data) {
  CefRefPtr<CefDictionaryValue> object = ParseObject(json);
  if (!object) {
    return false;
  }
  if (object->HasKey("text")) {
    data->SetFragmentText(object->GetString("text"));
  }
  if (object->HasKey("html")) {
    data->SetFragmentHtml(object->GetString("html"));
  }
  if (object->HasKey("url")) {
    data->SetLinkURL(object->GetString("url"));
  }
  if (object->HasKey("urlTitle")) {
    data->SetLinkTitle(object->GetString("urlTitle"));
  }
  if (CefRefPtr<CefListValue> paths = object->GetList("paths")) {
    for (size_t index = 0; index < paths->GetSize(); ++index) {
      const std::string path = paths->GetString(index).ToString();
      data->AddFile(path, Basename(path));
    }
  }
  return true;
}

/// Writes a dragged virtual file (an image dragged out of the page) to a private temporary
/// directory so the client can offer it as a file URL. Returns its path, or empty.
std::string WriteDraggedFile(CefRefPtr<CefDragData> data, std::string* error) {
  std::string name = Basename(data->GetFileName().ToString());
  if (name.empty() || name == "." || name == "..") {
    name = "dragged-file";
  }
  std::string directory_template =
      std::string(NSTemporaryDirectory().fileSystemRepresentation) + "/owl-drag-XXXXXX";
  const char* directory = mkdtemp(directory_template.data());
  if (directory == nullptr) {
    *error = "Could not create a directory for the dragged file.";
    return "";
  }
  const std::string path = std::string(directory) + "/" + name;
  CefRefPtr<CefStreamWriter> writer = CefStreamWriter::CreateForFile(path);
  if (!writer || data->GetFileContents(writer) == 0) {
    *error = "Could not write the dragged file " + name + ".";
    return "";
  }
  writer->Flush();
  return path;
}

}  // namespace

// MARK: IME

void BrowserClient::HandleImeCommand(uint16_t kind, const Decoder& fields) {
  if (!browser_) {
    return;
  }
  CefRefPtr<CefBrowserHost> host = browser_->GetHost();
  switch (kind) {
    case OWLMessageKindImeSetComposition: {
      const CefString text = fields.String(OWLFieldText).value_or("");
      if (text.empty()) {
        host->ImeCancelComposition();  // An empty composition asserts in the renderer.
        return;
      }
      CefCompositionUnderline underline{};
      underline.size = sizeof(underline);
      underline.range = CefRange(0, static_cast<uint32_t>(text.length()));
      underline.color = CefColorSetARGB(255, 0, 0, 0);
      underline.background_color = CefColorSetARGB(0, 0, 0, 0);
      underline.style = CEF_CUS_SOLID;
      host->ImeSetComposition(text, {underline},
                              RangeFrom(fields, OWLFieldReplaceStart, OWLFieldReplaceEnd),
                              RangeFrom(fields, OWLFieldRangeStart, OWLFieldRangeEnd));
      return;
    }
    case OWLMessageKindImeCommitText:
      if (fields.Bool(OWLFieldAgentInput).value_or(false)) {
        FocusForAgent(OWLInputOriginAgent);
      }
      host->ImeCommitText(fields.String(OWLFieldText).value_or(""),
                          RangeFrom(fields, OWLFieldReplaceStart, OWLFieldReplaceEnd),
                          static_cast<int>(fields.I64(OWLFieldCursorPosition).value_or(0)));
      return;
    case OWLMessageKindImeFinishComposing:
      host->ImeFinishComposingText(fields.Bool(OWLFieldKeepSelection).value_or(false));
      return;
    default:
      host->ImeCancelComposition();
      return;
  }
}

void BrowserClient::OnImeCompositionRangeChanged(CefRefPtr<CefBrowser>,
                                                 const CefRange& selected_range,
                                                 const RectList& character_bounds) {
  if (!ClientHandlesPrompts()) {
    return;
  }
  CefRefPtr<CefListValue> rects = CefListValue::Create();
  for (const CefRect& bounds : character_bounds) {
    CefRefPtr<CefListValue> rect = CefListValue::Create();
    rect->SetInt(0, bounds.x);
    rect->SetInt(1, bounds.y);
    rect->SetInt(2, bounds.width);
    rect->SetInt(3, bounds.height);
    rects->SetList(rects->GetSize(), rect);
  }
  Emit(OWLMessageKindImeCompositionChanged,
       Encoder()
           .I64(OWLFieldRangeStart, selected_range.from)
           .I64(OWLFieldRangeEnd, selected_range.to)
           .String(OWLFieldRects, WriteJSON(rects)));
}

void BrowserClient::OnTextSelectionChanged(CefRefPtr<CefBrowser>, const CefString& selected_text,
                                           const CefRange& selected_range) {
  if (!ClientHandlesPrompts()) {
    return;
  }
  Emit(OWLMessageKindTextSelectionChanged, Encoder()
                                               .String(OWLFieldText, selected_text.ToString())
                                               .I64(OWLFieldRangeStart, selected_range.from)
                                               .I64(OWLFieldRangeEnd, selected_range.to));
}

// MARK: Drag and drop

void BrowserClient::HandleDragCommand(uint16_t kind, const Decoder& fields) {
  if (!browser_) {
    return;
  }
  CefRefPtr<CefBrowserHost> host = browser_->GetHost();
  const auto operations = static_cast<cef_drag_operations_mask_t>(
      fields.U64(OWLFieldDragOperations).value_or(DRAG_OPERATION_NONE));
  switch (kind) {
    case OWLMessageKindDragEnter: {
      CefRefPtr<CefDragData> data = CefDragData::Create();
      if (!DragDataFromJSON(fields.String(OWLFieldDragData).value_or(""), data)) {
        Host::Get().ReportError(view_id_, OWLHostErrorMalformedMessage,
                                "DragEnter needs a DragData JSON object.");
        return;
      }
      host->DragTargetDragEnter(data, MouseEventFrom(fields), operations);
      return;
    }
    case OWLMessageKindDragOver:
      host->DragTargetDragOver(MouseEventFrom(fields), operations);
      return;
    case OWLMessageKindDragLeave:
      host->DragTargetDragLeave();
      return;
    case OWLMessageKindDragDrop:
      host->DragTargetDrop(MouseEventFrom(fields));
      return;
    default: {
      const CefMouseEvent event = MouseEventFrom(fields);
      host->DragSourceEndedAt(event.x, event.y, operations);
      host->DragSourceSystemDragEnded();
      return;
    }
  }
}

bool BrowserClient::StartDragging(CefRefPtr<CefBrowser>, CefRefPtr<CefDragData> drag_data,
                                  DragOperationsMask allowed_ops, int x, int y) {
  if (!ClientHandlesPrompts() || last_pointer_origin_ == OWLInputOriginAgent) {
    return false;  // Agent drags never leave the page.
  }
  CefRefPtr<CefDictionaryValue> object = CefDictionaryValue::Create();
  if (!drag_data->GetFragmentText().empty()) {
    object->SetString("text", drag_data->GetFragmentText());
  }
  if (!drag_data->GetFragmentHtml().empty()) {
    object->SetString("html", drag_data->GetFragmentHtml());
  }
  if (drag_data->IsLink()) {
    object->SetString("url", drag_data->GetLinkURL());
    object->SetString("urlTitle", drag_data->GetLinkTitle());
  }
  std::vector<std::string> paths;
  if (!drag_data->GetFileName().empty()) {
    std::string error;
    const std::string path = WriteDraggedFile(drag_data, &error);
    if (path.empty()) {
      Host::Get().ReportError(view_id_, OWLHostErrorMalformedMessage, error);
    } else {
      object->SetString("fileName", Basename(path));
      paths.push_back(path);
    }
  }
  if (!paths.empty()) {
    object->SetList("paths", StringList(paths));
  }
  Encoder fields;
  fields.U64(OWLFieldDragOperations, static_cast<uint64_t>(allowed_ops))
      .Double(OWLFieldX, x - screen_x_)
      .Double(OWLFieldY, y - screen_y_)
      .String(OWLFieldDragData, WriteJSON(object));
  if (drag_data->HasImage()) {
    int pixel_width = 0;
    int pixel_height = 0;
    CefRefPtr<CefBinaryValue> png = drag_data->GetImage()->GetAsPNG(
        static_cast<float>(scale_), true, pixel_width, pixel_height);
    if (png && png->GetSize() > 0) {
      std::vector<uint8_t> bytes(png->GetSize());
      png->GetData(bytes.data(), bytes.size(), 0);
      fields.Bytes(OWLFieldImage, bytes.data(), bytes.size());
    }
  }
  Emit(OWLMessageKindStartDrag, fields);
  return true;
}

void BrowserClient::UpdateDragCursor(CefRefPtr<CefBrowser>, DragOperation operation) {
  if (ClientHandlesPrompts()) {
    Emit(OWLMessageKindDragCursor,
         Encoder().U64(OWLFieldDragOperations, static_cast<uint64_t>(operation)));
  }
}

// MARK: <input type=color>

void BrowserClient::RunInternalDevTools(const std::string& method,
                                        CefRefPtr<CefDictionaryValue> params) {
  if (!browser_) {
    return;
  }
  const int message_id = ++next_message_id_;
  pending_devtools_[message_id] = PendingDevTools{0, OWLMessageKindDevToolsResult};
  if (browser_->GetHost()->ExecuteDevToolsMethod(message_id, method, params) == 0) {
    pending_devtools_.erase(message_id);
    Host::Get().ReportError(view_id_, OWLHostErrorDevToolsFailed,
                            "CEF rejected the internal DevTools call " + method + ".");
  }
}

void BrowserClient::InstallPageBridge() {
  RunInternalDevTools("Runtime.enable", nullptr);
  RunInternalDevTools("Page.enable", nullptr);
  CefRefPtr<CefDictionaryValue> binding = CefDictionaryValue::Create();
  binding->SetString("name", kColorBinding);
  binding->SetString("executionContextName", kBridgeWorld);
  RunInternalDevTools("Runtime.addBinding", binding);
  CefRefPtr<CefDictionaryValue> script = CefDictionaryValue::Create();
  script->SetString("source", kBridgeSource);
  script->SetString("worldName", kBridgeWorld);
  script->SetBool("runImmediately", true);
  RunInternalDevTools("Page.addScriptToEvaluateOnNewDocument", script);
}

void BrowserClient::OnDevToolsEvent(CefRefPtr<CefBrowser>, const CefString& method,
                                    const void* params, size_t params_size) {
  if (method != "Runtime.bindingCalled") {
    return;  // Domain events the bridge enables (console, contexts) are not needed here.
  }
  CefRefPtr<CefDictionaryValue> event =
      ParseObject(std::string(static_cast<const char*>(params), params_size));
  if (!event || event->GetString("name") != kColorBinding) {
    return;
  }
  CefRefPtr<CefDictionaryValue> payload = ParseObject(event->GetString("payload").ToString());
  if (!payload) {
    Host::Get().ReportError(view_id_, OWLHostErrorMalformedMessage,
                            "The color bridge sent a malformed payload.");
    return;
  }
  const uint64_t prompt_id = NextPromptID();
  color_requests_[prompt_id] =
      PendingColor{event->GetInt("executionContextId"), payload->GetInt("id")};
  Emit(OWLMessageKindColorChooser, Encoder()
                                       .U64(OWLFieldPromptID, prompt_id)
                                       .String(OWLFieldColor, payload->GetString("value").ToString()));
}

void BrowserClient::HandleColorReply(const Decoder& fields) {
  const uint64_t prompt_id = fields.U64(OWLFieldPromptID).value_or(0);
  auto found = color_requests_.find(prompt_id);
  if (found == color_requests_.end()) {
    UnknownPrompt(OWLMessageKindColorReply, prompt_id);
    return;
  }
  const PendingColor pending = found->second;
  color_requests_.erase(found);
  if (!fields.Bool(OWLFieldAccepted).value_or(false)) {
    return;
  }
  const std::string color = fields.String(OWLFieldColor).value_or("");
  static const std::regex kHexColor("^#[0-9a-fA-F]{6}$");
  if (!std::regex_match(color, kHexColor)) {
    Host::Get().ReportError(view_id_, OWLHostErrorMalformedMessage,
                            "ColorReply needs a #rrggbb Color.");
    return;
  }
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("expression", "globalThis.__owlBridge.setColor(" +
                                      std::to_string(pending.element_id) + ", '" + color + "')");
  params->SetInt("contextId", pending.context_id);
  RunInternalDevTools("Runtime.evaluate", params);
}

}  // namespace owl
