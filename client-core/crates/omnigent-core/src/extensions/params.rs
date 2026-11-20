//! The checks each host method's parameters pass, and the results it answers with, as the web's
//! `services/useExtensionHostServices.ts`, `projects.ts` and `storage.ts` make them.

use serde_json::{Map, Value, json};

use super::{ExtensionHostError, ExtensionPage, bounded};

/// The longest session or project id a method takes.
const MAX_ID_CHARS: usize = 256;
/// The longest project name.
const MAX_PROJECT_NAME_CHARS: usize = 100;
/// The longest project icon.
const MAX_PROJECT_ICON_CHARS: usize = 16;
/// The longest PR title answered.
const MAX_PULL_REQUEST_TITLE_CHARS: usize = 256;
/// The longest storage key.
const MAX_STORAGE_KEY_CHARS: usize = 128;
/// The largest stored value, as JSON text.
const MAX_STORAGE_VALUE_BYTES: usize = 32 * 1024;

fn object(params: Option<&Value>) -> Result<&Map<String, Value>, ExtensionHostError> {
    params
        .and_then(Value::as_object)
        .ok_or_else(|| ExtensionHostError::invalid_params("Expected an object"))
}

fn id_param(
    params: Option<&Value>,
    key: &str,
    problem: &str,
) -> Result<String, ExtensionHostError> {
    match object(params)?.get(key) {
        Some(Value::String(id)) if !id.is_empty() && id.chars().count() <= MAX_ID_CHARS => {
            Ok(id.clone())
        }
        _ => Err(ExtensionHostError::invalid_params(problem)),
    }
}

/// `navigation.openPage`: the route of the extension's page `pageId`. Its `params` must be
/// strings, numbers or booleans; a native page has no query, so they go no further.
///
/// # Errors
///
/// `InvalidParams` for a missing page id or a bad parameter; `PermissionDenied` for a page the
/// extension does not own.
pub fn page_route_param(
    params: Option<&Value>,
    pages: &[ExtensionPage],
) -> Result<String, ExtensionHostError> {
    let input = object(params)?;
    let Some(Value::String(page_id)) = input.get("pageId") else {
        return Err(ExtensionHostError::invalid_params("pageId is required"));
    };
    let page = pages
        .iter()
        .find(|page| &page.id == page_id)
        .ok_or_else(|| {
            ExtensionHostError::new("PermissionDenied", "Page is not owned by extension")
        })?;
    match input.get("params") {
        None => {}
        Some(Value::Object(values)) => {
            for (key, value) in values {
                if !matches!(value, Value::String(_) | Value::Number(_) | Value::Bool(_)) {
                    return Err(ExtensionHostError::invalid_params(format!(
                        "Page parameter {key} is invalid"
                    )));
                }
            }
        }
        Some(_) => return Err(ExtensionHostError::invalid_params("Expected an object")),
    }
    Ok(page.route.clone())
}

/// `navigation.openSession` and `sessions.pullRequest`: the session id.
///
/// # Errors
///
/// `InvalidParams` for a missing, empty or over-long id.
pub fn session_id_param(params: Option<&Value>) -> Result<String, ExtensionHostError> {
    id_param(params, "sessionId", "sessionId is invalid")
}

/// `navigation.openNewSession`: the project to start in, if any.
///
/// # Errors
///
/// `InvalidParams` for a project id that is not a non-empty string.
pub fn new_session_project_param(
    params: Option<&Value>,
) -> Result<Option<String>, ExtensionHostError> {
    if params.is_none() {
        return Ok(None);
    }
    match object(params)?.get("projectId") {
        None | Some(Value::Null) => Ok(None),
        Some(_) => id_param(params, "projectId", "projectId is invalid").map(Some),
    }
}

/// `navigation.openExternal`: the URL. The host then opens it only if it handed it out.
///
/// # Errors
///
/// `PermissionDenied` for anything but a string, as no other value was handed out.
pub fn external_url_param(params: Option<&Value>) -> Result<String, ExtensionHostError> {
    match object(params)?.get("url") {
        Some(Value::String(url)) => Ok(url.clone()),
        _ => Err(ExtensionHostError::new(
            "PermissionDenied",
            "URL was not provided by the host",
        )),
    }
}

/// `projects.create`: the trimmed name.
///
/// # Errors
///
/// `InvalidParams` for a missing name or one outside 1 to 100 characters once trimmed.
pub fn project_name_param(params: Option<&Value>) -> Result<String, ExtensionHostError> {
    let Some(Value::String(name)) = object(params)?.get("name") else {
        return Err(ExtensionHostError::invalid_params("name is required"));
    };
    let trimmed = name.trim();
    let length = trimmed.chars().count();
    if !(1..=MAX_PROJECT_NAME_CHARS).contains(&length) {
        return Err(ExtensionHostError::invalid_params(format!(
            "name must be 1 to {MAX_PROJECT_NAME_CHARS} characters"
        )));
    }
    Ok(trimmed.to_owned())
}

/// `storage.user.get` and `storage.user.delete`: the key, 1 to 128 characters of letters,
/// digits, `.`, `_` and `-`, starting with a letter or digit.
///
/// # Errors
///
/// `InvalidParams` for parameters that are not an object; `InvalidKey` for a bad key.
pub fn storage_key_param(params: Option<&Value>) -> Result<String, ExtensionHostError> {
    let input = object(params)?;
    let invalid = || ExtensionHostError::new("InvalidKey", "Storage key is invalid");
    let Some(Value::String(key)) = input.get("key") else {
        return Err(invalid());
    };
    let mut characters = key.chars();
    let first_ok = characters
        .next()
        .is_some_and(|first| first.is_ascii_alphanumeric());
    let rest_ok = characters
        .all(|character| character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-'));
    if !first_ok || !rest_ok || key.chars().count() > MAX_STORAGE_KEY_CHARS {
        return Err(invalid());
    }
    Ok(key.clone())
}

/// A value to store under a key.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct StorageWrite {
    /// The key.
    pub key: String,
    /// The value as JSON text.
    pub json: String,
    /// Its size in UTF-8 bytes, which the quota counts.
    pub size: u64,
}

/// `storage.user.set`: the key and the value as JSON text.
///
/// # Errors
///
/// As [`storage_key_param`]; `InvalidValue` without a value; `QuotaExceeded` for a value over
/// 32 KB.
pub fn storage_write_param(params: Option<&Value>) -> Result<StorageWrite, ExtensionHostError> {
    let key = storage_key_param(params)?;
    let value = object(params)?.get("value").ok_or_else(|| {
        ExtensionHostError::new("InvalidValue", "Storage value must be JSON serializable")
    })?;
    let json = value.to_string();
    if json.len() > MAX_STORAGE_VALUE_BYTES {
        return Err(ExtensionHostError::new(
            "QuotaExceeded",
            "Storage value exceeds 32 KB",
        ));
    }
    Ok(StorageWrite {
        size: u64::try_from(json.len()).unwrap_or(u64::MAX),
        key,
        json,
    })
}

/// A project as an extension sees it: id, name (cut to 100 characters) and icon (cut to 16).
///
/// # Errors
///
/// `HostError` for a project without a usable id.
pub fn project_result(
    id: Option<&str>,
    name: &str,
    icon: Option<&str>,
) -> Result<Value, ExtensionHostError> {
    let id = id
        .filter(|id| !id.is_empty() && id.chars().count() <= MAX_ID_CHARS)
        .ok_or_else(|| ExtensionHostError::host("Project id is malformed"))?;
    let icon = icon
        .filter(|icon| !icon.is_empty())
        .map(|icon| bounded(icon, MAX_PROJECT_ICON_CHARS));
    Ok(json!({"id": id, "name": bounded(name, MAX_PROJECT_NAME_CHARS), "icon": icon}))
}

/// `projects.list`: the first-class projects; label-only ones have no id to give.
#[must_use]
pub fn cached_projects_result(projects: &[(Option<String>, String, Option<String>)]) -> Value {
    Value::Array(
        projects
            .iter()
            .filter_map(|(id, name, icon)| {
                project_result(id.as_deref(), name, icon.as_deref()).ok()
            })
            .collect(),
    )
}

/// `sessions.pullRequest`: the PR, or `null` for none or one whose page is not `https`.
#[must_use]
pub fn pull_request_result(number: u64, title: &str, state: &str, url: &str) -> Value {
    if !url.starts_with("https://") {
        return Value::Null;
    }
    json!({
        "number": number,
        "title": bounded(title, MAX_PULL_REQUEST_TITLE_CHARS),
        "state": state,
        "url": url,
    })
}

/// `theme.getCurrent` and `theme.subscribe`, and the `theme.changed` event.
#[must_use]
pub fn theme_result(dark: bool) -> Value {
    json!({"theme": if dark { "dark" } else { "light" }})
}
