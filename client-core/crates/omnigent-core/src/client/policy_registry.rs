//! Default policies from the policy registry, and member invites.
//!
//! As the web's Policies page: `GET /v1/policy-registry` lists the built-in handlers with their
//! parameter schemas, the form's text values are coerced by schema type, and `POST
//! /v1/policies` adds one. `POST /auth/invite` mints a register link.

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use super::json::{as_object, opt_array, opt_object, opt_str, req_str};
use super::server_admin::DefaultPolicy;
use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

/// How a parameter is edited and coerced.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PolicyParamKind {
    /// Free text, sent as typed (`string` and unknown schema types).
    Text,
    /// A whole number.
    Integer,
    /// Any number.
    Number,
    /// `true` or `false`.
    Boolean,
    /// One of [`PolicyParam::options`].
    Choice,
    /// A comma-separated list.
    List,
    /// Any of [`PolicyParam::options`], comma-separated.
    MultiChoice,
    /// A JSON object.
    Object,
}

/// One parameter of a factory policy.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PolicyParam {
    /// The parameter name.
    pub key: String,
    /// How it is edited.
    pub kind: PolicyParamKind,
    /// The schema's description.
    pub description: Option<String>,
    /// The schema default as form text (`true`, `a, b`, `{"x": 1}`); empty when none.
    pub default_value: String,
    /// The allowed values of a choice.
    pub options: Vec<String>,
    /// The schema lists it as required.
    pub required: bool,
}

/// A built-in policy handler (`GET /v1/policy-registry`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PolicyRegistryEntry {
    /// The handler path, which identifies it.
    pub handler: String,
    /// Display name.
    pub name: String,
    /// What it does.
    pub description: String,
    /// A factory takes parameters (`factory_params`); a callable takes none.
    pub is_factory: bool,
    /// The parameters, by name.
    pub params: Vec<PolicyParam>,
}

/// The name the add form suggests for `entry`: its display name in `snake_case`, as the web.
#[must_use]
pub fn suggested_policy_name(entry: &PolicyRegistryEntry) -> String {
    entry
        .name
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("_")
}

fn default_text(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| {
                item.as_str()
                    .map_or_else(|| item.to_string(), str::to_owned)
            })
            .collect::<Vec<_>>()
            .join(", "),
        Some(other) => other.to_string(),
    }
}

fn string_options(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

fn param_from(key: &str, schema: &Value, required: &[String]) -> Result<PolicyParam, String> {
    let object = as_object(schema, key)?;
    let schema_type = opt_str(object, "type")?;
    let choices = string_options(object.get("enum"));
    let item_choices = opt_object(object, "items")?
        .map(|items| string_options(items.get("enum")))
        .unwrap_or_default();
    let (kind, options) = match schema_type.as_deref() {
        Some("integer") => (PolicyParamKind::Integer, Vec::new()),
        Some("number") => (PolicyParamKind::Number, Vec::new()),
        Some("boolean") => (PolicyParamKind::Boolean, Vec::new()),
        Some("object") => (PolicyParamKind::Object, Vec::new()),
        Some("array") if !item_choices.is_empty() => (PolicyParamKind::MultiChoice, item_choices),
        Some("array") => (PolicyParamKind::List, Vec::new()),
        _ if !choices.is_empty() => (PolicyParamKind::Choice, choices),
        _ => (PolicyParamKind::Text, Vec::new()),
    };
    Ok(PolicyParam {
        key: key.to_owned(),
        kind,
        description: opt_str(object, "description")?,
        default_value: default_text(object.get("default")),
        options,
        required: required.iter().any(|name| name == key),
    })
}

fn entry_from(value: &Value) -> Result<PolicyRegistryEntry, String> {
    let object = as_object(value, "policy registry entry")?;
    let mut params = Vec::new();
    if let Some(schema) = opt_object(object, "params_schema")? {
        let required: Vec<String> = string_options(schema.get("required"));
        if let Some(properties) = opt_object(schema, "properties")? {
            for (key, property) in properties {
                params.push(param_from(key, property, &required)?);
            }
        }
    }
    Ok(PolicyRegistryEntry {
        handler: req_str(object, "handler")?,
        name: req_str(object, "name")?,
        description: opt_str(object, "description")?.unwrap_or_default(),
        is_factory: opt_str(object, "kind")?.as_deref() == Some("factory"),
        params,
    })
}

/// The form's `values` as `factory_params`, by each parameter's kind. Empty values are left out
/// so the server applies its defaults.
///
/// # Errors
///
/// The first value that is not of its kind, as a sentence for the form.
pub fn coerce_policy_params(
    params: &[PolicyParam],
    values: &BTreeMap<String, String>,
) -> Result<Map<String, Value>, String> {
    let mut coerced = Map::new();
    for param in params {
        let Some(raw) = values.get(&param.key).map(|raw| raw.trim()) else {
            continue;
        };
        if raw.is_empty() {
            continue;
        }
        let key = &param.key;
        let value = match param.kind {
            PolicyParamKind::Integer => raw
                .parse::<i64>()
                .map(Value::from)
                .map_err(|_| format!("{key} must be an integer, e.g. 20"))?,
            PolicyParamKind::Number => raw
                .parse::<f64>()
                .ok()
                .filter(|number| number.is_finite())
                .map(Value::from)
                .ok_or_else(|| format!("{key} must be a number, e.g. 0.5"))?,
            PolicyParamKind::Boolean => Value::Bool(raw == "true"),
            PolicyParamKind::List | PolicyParamKind::MultiChoice => Value::Array(
                raw.split(',')
                    .map(str::trim)
                    .filter(|item| !item.is_empty())
                    .map(|item| Value::String(item.to_owned()))
                    .collect(),
            ),
            PolicyParamKind::Object => match serde_json::from_str::<Value>(raw) {
                Ok(object @ Value::Object(_)) => object,
                Ok(_) => {
                    return Err(format!(
                        r#"{key} must be a JSON object, e.g. {{"web_search": 10}}"#
                    ));
                }
                Err(_) => {
                    return Err(format!(
                        r#"{key} must be valid JSON, e.g. {{"web_search": 10}}"#
                    ));
                }
            },
            PolicyParamKind::Text | PolicyParamKind::Choice => Value::String(raw.to_owned()),
        };
        coerced.insert(key.clone(), value);
    }
    Ok(coerced)
}

const fn rejected(message: String) -> SessionError {
    SessionError::Rejected {
        status: 400,
        message,
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// The built-in policy handlers (`GET /v1/policy-registry`), in server order.
    ///
    /// # Errors
    ///
    /// The read errors; [`SessionError::MalformedResponse`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn policy_registry(&self) -> Result<Vec<PolicyRegistryEntry>, SessionError> {
        let path = "/v1/policy-registry";
        let result = self.get_json(path, &[]).await;
        self.dispatch();
        let malformed = |detail: String| SessionError::MalformedResponse {
            detail: format!("{path}: {detail}"),
        };
        let value = result?;
        let object = as_object(&value, path).map_err(malformed)?;
        opt_array(object, "data")
            .map_err(malformed)?
            .ok_or_else(|| malformed("`data` is missing".into()))?
            .iter()
            .map(entry_from)
            .collect::<Result<_, _>>()
            .map_err(malformed)
    }

    /// Adds `entry` as a server-wide default policy named `name` (`POST /v1/policies`), with
    /// the form's parameter `values` coerced by [`coerce_policy_params`].
    ///
    /// # Errors
    ///
    /// `Rejected` (400) before any request for an empty name or a value of the wrong kind; the
    /// write errors; `DeliveryUncertain` for an unreadable acknowledgement.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn add_default_policy(
        &self,
        entry: &PolicyRegistryEntry,
        name: &str,
        values: &BTreeMap<String, String>,
    ) -> Result<DefaultPolicy, SessionError> {
        let name = name.trim();
        if name.is_empty() {
            return Err(rejected("Name the policy.".to_owned()));
        }
        let mut body = Map::new();
        body.insert("name".into(), json!(name));
        body.insert("type".into(), json!("python"));
        body.insert("handler".into(), json!(entry.handler));
        if entry.is_factory {
            let params = coerce_policy_params(&entry.params, values).map_err(rejected)?;
            body.insert("factory_params".into(), Value::Object(params));
        }
        let body = Value::Object(body);
        let result = async {
            let reply = self.write_json("POST", "/v1/policies", &body).await?;
            super::server_admin::policy_from(&reply).map_err(|detail| {
                SessionError::DeliveryUncertain {
                    detail: format!("unreadable /v1/policies acknowledgement: {detail}"),
                }
            })
        }
        .await;
        self.dispatch();
        result
    }

    /// Mints a single-use invite link for a new password account (`POST /auth/invite`, admins
    /// on accounts servers), on the connected server's address as the web rebases it.
    ///
    /// # Errors
    ///
    /// `NotConnected`; `Forbidden` for a non-admin; the write errors; `DeliveryUncertain` when
    /// the acknowledgement has no token.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn invite_member(&self, is_admin: bool) -> Result<MemberInvite, SessionError> {
        let result = async {
            let base = self
                .connected_server()
                .ok_or(SessionError::NotConnected)?
                .base_url;
            let reply = self
                .write_json("POST", "/auth/invite", &json!({"is_admin": is_admin}))
                .await?;
            invite_from(&reply, &base).map_err(|detail| SessionError::DeliveryUncertain {
                detail: format!("unreadable /auth/invite acknowledgement: {detail}"),
            })
        }
        .await;
        self.dispatch();
        result
    }
}

/// A minted invite (`POST /auth/invite`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct MemberInvite {
    /// The register link to send, on the connected server's address.
    pub url: String,
    /// Expiry, Unix seconds.
    pub expires_at: Option<i64>,
    /// The account it creates is an administrator.
    pub is_admin: bool,
}

/// Decodes an invite reply, building the register link on `base_url`.
///
/// # Errors
///
/// A description of the first field with the wrong shape.
pub fn invite_from(value: &Value, base_url: &str) -> Result<MemberInvite, String> {
    let object = as_object(value, "invite")?;
    let token = req_str(object, "token")?;
    if token.is_empty() {
        return Err("`token` is empty".to_owned());
    }
    let encoded: String = url::form_urlencoded::byte_serialize(token.as_bytes()).collect();
    Ok(MemberInvite {
        url: format!(
            "{}/register?invite={encoded}",
            base_url.trim_end_matches('/')
        ),
        expires_at: object.get("expires_at").and_then(Value::as_i64),
        is_admin: object
            .get("is_admin")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}

#[cfg(test)]
#[path = "policy_registry_tests.rs"]
mod tests;
