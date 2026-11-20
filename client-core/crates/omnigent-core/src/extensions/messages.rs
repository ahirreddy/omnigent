//! Bridge messages: what an extension may send (checked as the web's `rpc/validation.ts`
//! checks it), what the host sends back, and which host methods a manifest's permissions grant
//! (`services/registry.ts`).

#![allow(
    clippy::redundant_pub_crate,
    reason = "crate-internal helpers of a private module; `pub` would trip rustc's unreachable_pub"
)]

use std::collections::BTreeSet;

use serde_json::{Map, Value, json};

use super::{
    EXTENSION_RPC_SOURCE, ExtensionIdentity, MAX_ERROR_CHARS, MAX_EXTENSION_MESSAGE_BYTES, bounded,
};

const MAX_MESSAGE_NODES: usize = 5_000;
/// A session page goes one way, from the host, so it may be larger than any request.
const MAX_SESSION_PAGE_BYTES: usize = 512 * 1024;
const MAX_SESSION_PAGE_NODES: usize = 25_000;
const MAX_DEPTH: usize = 20;
const MAX_OBJECT_ENTRIES: usize = 256;
/// What a number, boolean or null costs in a budget.
const SCALAR_BYTES: usize = 8;

/// Every host method, with the permission that grants it (`None`: every extension).
const HOST_METHODS: [(&str, Option<&str>); 14] = [
    ("navigation.openPage", Some("navigation")),
    ("navigation.openSession", Some("navigation")),
    ("navigation.openNewSession", Some("navigation")),
    ("navigation.openExternal", Some("navigation")),
    ("theme.getCurrent", None),
    ("theme.subscribe", None),
    ("storage.user.get", Some("storage.user")),
    ("storage.user.set", Some("storage.user")),
    ("storage.user.delete", Some("storage.user")),
    ("sessions.getCached", Some("sessions.read")),
    ("sessions.listPage", Some("sessions.read")),
    ("sessions.pullRequest", Some("sessions.read")),
    ("projects.list", Some("projects.read")),
    ("projects.create", Some("projects.write")),
];

/// The permission a host method needs: `Some(None)` for one every extension may call, `None`
/// for a method the host does not have.
#[must_use]
pub fn host_method_permission(method: &str) -> Option<Option<&'static str>> {
    HOST_METHODS
        .iter()
        .find(|(name, _)| *name == method)
        .map(|(_, permission)| *permission)
}

/// The host methods `permissions` grant, sorted: the `capabilities` of `init`.
#[must_use]
pub fn granted_host_methods(permissions: &[String]) -> Vec<String> {
    let mut granted: Vec<String> = HOST_METHODS
        .iter()
        .filter(|(_, permission)| {
            permission.is_none_or(|needed| permissions.iter().any(|held| held == needed))
        })
        .map(|(name, _)| (*name).to_owned())
        .collect();
    granted.sort();
    granted
}

/// A message from an extension's page.
#[derive(Debug, Clone, PartialEq)]
pub enum ExtensionInbound {
    /// The page activated.
    Ready,
    /// The page's SDK speaks another bridge version.
    Incompatible {
        /// The SDK's version.
        sdk_api_version: f64,
    },
    /// The page failed to activate.
    Failed {
        /// Why.
        message: String,
    },
    /// A host method call.
    Request {
        /// Unique among the page's requests in flight.
        request_id: String,
        /// The method.
        method: String,
        /// Its parameters, as sent.
        params: Option<Value>,
    },
    /// The page gave up on a request.
    Cancel {
        /// The request.
        request_id: String,
    },
}

/// The message in `text` (JSON) when it is a well-formed message for `identity` within the
/// budget; anything else is ignored, as the web ignores it.
#[must_use]
pub fn parse_inbound(text: &str, identity: &ExtensionIdentity) -> Option<ExtensionInbound> {
    let value: Value = serde_json::from_str(text).ok()?;
    let message = value.as_object()?;
    if !matches_identity(message, identity) || !within_budget(&value, false) {
        return None;
    }
    let text_field = |key: &str| message.get(key).and_then(Value::as_str).map(str::to_owned);
    match message.get("type").and_then(Value::as_str)? {
        "ready" => Some(ExtensionInbound::Ready),
        "incompatible" => Some(ExtensionInbound::Incompatible {
            sdk_api_version: message.get("sdkApiVersion")?.as_f64()?,
        }),
        "error" => Some(ExtensionInbound::Failed {
            message: bounded(&text_field("message")?, MAX_ERROR_CHARS),
        }),
        "cancel" => Some(ExtensionInbound::Cancel {
            request_id: text_field("requestId")?,
        }),
        "request" => Some(ExtensionInbound::Request {
            request_id: text_field("requestId")?,
            method: text_field("method")?,
            params: message.get("params").cloned(),
        }),
        _ => None,
    }
}

fn matches_identity(message: &Map<String, Value>, identity: &ExtensionIdentity) -> bool {
    let text = |key: &str| message.get(key).and_then(Value::as_str);
    text("source") == Some(EXTENSION_RPC_SOURCE)
        && text("extensionId") == Some(identity.extension_id.as_str())
        && text("pageId") == Some(identity.page_id.as_str())
        && text("view") == Some(identity.view.as_str())
        && text("nonce") == Some(identity.nonce.as_str())
        && message.get("apiVersion").and_then(Value::as_f64)
            == Some(f64::from(identity.api_version))
}

/// Whether `value` fits a message's budget, counted as the web counts it: strings at two bytes
/// a UTF-16 unit, other scalars at eight, at most 20 levels deep and 256 keys an object. A
/// session page (`session_page`) has a larger budget than any other message.
pub(crate) fn within_budget(value: &Value, session_page: bool) -> bool {
    let (bytes, nodes) = if session_page {
        (MAX_SESSION_PAGE_BYTES, MAX_SESSION_PAGE_NODES)
    } else {
        (MAX_EXTENSION_MESSAGE_BYTES, MAX_MESSAGE_NODES)
    };
    let mut budget = Budget { bytes, nodes };
    budget.visit(value, 0)
}

struct Budget {
    bytes: usize,
    nodes: usize,
}

impl Budget {
    const fn spend(&mut self, bytes: usize) -> bool {
        match self.bytes.checked_sub(bytes) {
            Some(left) => {
                self.bytes = left;
                true
            }
            None => false,
        }
    }

    const fn node(&mut self, depth: usize) -> bool {
        match self.nodes.checked_sub(1) {
            Some(left) if depth <= MAX_DEPTH => {
                self.nodes = left;
                true
            }
            _ => false,
        }
    }

    fn visit(&mut self, value: &Value, depth: usize) -> bool {
        if !self.node(depth) {
            return false;
        }
        match value {
            Value::Null | Value::Bool(_) | Value::Number(_) => self.spend(SCALAR_BYTES),
            Value::String(text) => self.text(text),
            Value::Array(items) => items.iter().all(|item| self.visit(item, depth + 1)),
            Value::Object(entries) => {
                entries.len() <= MAX_OBJECT_ENTRIES
                    && entries.iter().all(|(key, item)| {
                        self.node(depth + 1) && self.text(key) && self.visit(item, depth + 1)
                    })
            }
        }
    }

    fn text(&mut self, text: &str) -> bool {
        self.spend(text.encode_utf16().count().saturating_mul(2))
    }
}

fn envelope(identity: &ExtensionIdentity, kind: &str) -> Map<String, Value> {
    let mut message = Map::new();
    message.insert("extensionId".into(), json!(identity.extension_id));
    message.insert("pageId".into(), json!(identity.page_id));
    message.insert("view".into(), json!(identity.view));
    message.insert("nonce".into(), json!(identity.nonce));
    message.insert("apiVersion".into(), json!(identity.api_version));
    message.insert("source".into(), json!(EXTENSION_RPC_SOURCE));
    message.insert("type".into(), json!(kind));
    message
}

/// `init`, naming the host methods the page may call.
#[must_use]
pub fn init_message(identity: &ExtensionIdentity, capabilities: &[String]) -> String {
    let unique: BTreeSet<&String> = capabilities.iter().collect();
    let mut message = envelope(identity, "init");
    message.insert("capabilities".into(), json!(unique));
    Value::Object(message).to_string()
}

/// The answer to `request_id`: `result`, or `ResponseTooLarge` when it is over the budget (a
/// session page's for `sessions.listPage` and `sessions.getCached`).
#[must_use]
pub fn response_message(
    identity: &ExtensionIdentity,
    request_id: &str,
    method: &str,
    result: &Value,
) -> String {
    let session_page = matches!(method, "sessions.listPage" | "sessions.getCached");
    if !within_budget(result, session_page) {
        return error_response_message(
            identity,
            request_id,
            "ResponseTooLarge",
            "Host response exceeds the limit",
        );
    }
    let mut message = envelope(identity, "response");
    message.insert("requestId".into(), json!(request_id));
    message.insert("result".into(), result.clone());
    Value::Object(message).to_string()
}

/// A failed answer to `request_id`; the message is cut to 512 characters.
#[must_use]
pub fn error_response_message(
    identity: &ExtensionIdentity,
    request_id: &str,
    code: &str,
    message: &str,
) -> String {
    let mut response = envelope(identity, "response");
    response.insert("requestId".into(), json!(request_id));
    response.insert(
        "error".into(),
        json!({"code": code, "message": bounded(message, MAX_ERROR_CHARS)}),
    );
    Value::Object(response).to_string()
}

/// An event for subscribers (`theme.changed`); `None` when it is over the budget.
#[must_use]
pub fn event_message(identity: &ExtensionIdentity, event: &str, value: &Value) -> Option<String> {
    let mut message = envelope(identity, "event");
    message.insert("event".into(), json!(event));
    message.insert("value".into(), value.clone());
    let message = Value::Object(message);
    within_budget(&message, false).then(|| message.to_string())
}

/// `dispose`: the page is going away.
#[must_use]
pub fn dispose_message(identity: &ExtensionIdentity) -> String {
    Value::Object(envelope(identity, "dispose")).to_string()
}
