//! The documents an extension page runs in: the bundle's sandboxed `srcdoc` document, as the
//! web's `buildExtensionDocument` writes it, and the native host page that frames it.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::json;

use super::ExtensionIdentity;

/// The bundle's sandboxed document.
///
/// A `#root`, a content security policy that allows only the nonce'd bootstrap and inline
/// styles (no network, forms or base URL), and the bootstrap, which sets
/// `__OMNIGENT_EXTENSION__` to `identity` and adds the styles and script, base64-encoded so no
/// bundle text can end the document's own script.
#[must_use]
pub fn build_extension_document(
    script: &str,
    styles: &str,
    identity: &ExtensionIdentity,
) -> String {
    let nonce = &identity.nonce;
    let serialized = json!({
        "extensionId": identity.extension_id,
        "pageId": identity.page_id,
        "view": identity.view,
        "nonce": identity.nonce,
        "apiVersion": identity.api_version,
    })
    .to_string()
    .replace('<', "\\u003c");
    let encoded_styles = STANDARD.encode(styles.as_bytes());
    let encoded_script = STANDARD.encode(script.as_bytes());
    let bootstrap = format!(
        "(()=>{{const d=(s)=>new TextDecoder().decode(Uint8Array.from(atob(s),c=>c.charCodeAt(0)));\
globalThis.__OMNIGENT_EXTENSION__={serialized};const style=document.createElement('style');\
style.textContent=d('{encoded_styles}');document.head.append(style);\
const script=document.createElement('script');script.nonce='{nonce}';\
script.textContent=d('{encoded_script}');document.body.append(script)}})();"
    );
    let csp = [
        "default-src 'none'".to_owned(),
        format!("script-src 'nonce-{nonce}'"),
        "style-src 'unsafe-inline'".to_owned(),
        "connect-src 'none'".to_owned(),
        "img-src data: blob:".to_owned(),
        "font-src data:".to_owned(),
        "form-action 'none'".to_owned(),
        "base-uri 'none'".to_owned(),
        "webrtc 'none'".to_owned(),
    ]
    .join("; ");
    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\">\
<meta http-equiv=\"Content-Security-Policy\" content=\"{csp}\">\
<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head>\
<body><div id=\"root\"></div><script nonce=\"{nonce}\">{bootstrap}</script></body></html>"
    )
}

/// The native host page: `document` in a frame sandboxed to scripts only (no same origin, so no
/// network, storage or access to this page), and the relay between that frame and the app.
///
/// The extension SDK takes its `init` only from its parent window, so this page opens the
/// `MessageChannel`: once the frame loads it tells the app (`loaded`; a second load is
/// `reloaded`), posts `init` with the channel's other port when the app hands it over
/// (`__omnigentHost.init`), sends the app's messages down the channel (`post`), and passes every
/// message from the extension to the app as JSON text. The app takes messages from this page's
/// main frame only.
#[must_use]
pub fn build_host_page(document: &str, title: &str, nonce: &str) -> String {
    let frame_document = json!(document).to_string().replace('<', "\\u003c");
    let frame_title = escape_attribute(title);
    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\">\
<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\
<style>html,body{{margin:0;height:100%;overflow:hidden;background:transparent}}\
iframe{{display:block;border:0;width:100%;height:100%}}</style></head>\
<body><iframe id=\"extension-frame\" title=\"{frame_title}\" sandbox=\"allow-scripts\" allow=\"\"></iframe>\
<script nonce=\"{nonce}\">(()=>{{\
const host=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.omnigentExtension;\
if(!host)return;\
const frame=document.getElementById('extension-frame');\
let channel=null;let loads=0;\
frame.addEventListener('load',()=>{{loads+=1;\
if(loads>1){{host.postMessage({{kind:'reloaded'}});return;}}\
channel=new MessageChannel();\
channel.port1.onmessage=(event)=>{{let text;try{{text=JSON.stringify(event.data);}}catch(error){{return;}}\
if(typeof text==='string')host.postMessage({{kind:'message',text}});}};\
channel.port1.start();host.postMessage({{kind:'loaded'}});}});\
window.__omnigentHost={{\
init(text){{if(!channel||!frame.contentWindow)return false;\
frame.contentWindow.postMessage(JSON.parse(text),'*',[channel.port2]);return true;}},\
post(text){{if(!channel)return false;channel.port1.postMessage(JSON.parse(text));return true;}},\
close(){{if(!channel)return;channel.port1.onmessage=null;channel.port1.close();channel=null;}}}};\
frame.srcdoc={frame_document};}})();</script></body></html>"
    )
}

fn escape_attribute(text: &str) -> String {
    text.chars()
        .map(|character| match character {
            '&' => "&amp;".to_owned(),
            '"' => "&quot;".to_owned(),
            '<' => "&lt;".to_owned(),
            '>' => "&gt;".to_owned(),
            other => other.to_string(),
        })
        .collect()
}
