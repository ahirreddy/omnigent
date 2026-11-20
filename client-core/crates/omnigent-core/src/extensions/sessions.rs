//! `sessions.listPage` and `sessions.getCached`: the caller's sessions as an extension sees
//! them, a bounded projection of the server's rows (the web's `services/sessions.ts`).

use serde_json::{Map, Value, json};

use super::messages::within_budget;
use super::{ExtensionHostError, bounded};

/// Sessions a page has when the extension does not say.
const DEFAULT_PAGE_LIMIT: u32 = 25;
/// The most sessions a page may ask for.
const MAX_PAGE_LIMIT: u32 = 1_000;
const MAX_CURSOR_CHARS: usize = 256;
const MAX_ID_CHARS: usize = 256;
const MAX_TITLE_CHARS: usize = 256;
const MAX_WORKSPACE_CHARS: usize = 512;
const STATUSES: [&str; 4] = ["idle", "running", "waiting", "failed"];

/// Where a page starts and how many sessions it has.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SessionPageRequest {
    /// The cursor of the page before; `None` for the first page.
    pub after: Option<String>,
    /// 1 to 1,000 sessions.
    pub limit: u32,
}

/// The page `params` asks for.
///
/// # Errors
///
/// `InvalidParams` for a bad cursor or limit.
pub fn session_page_request(
    params: Option<&Value>,
) -> Result<SessionPageRequest, ExtensionHostError> {
    let input = params
        .and_then(Value::as_object)
        .ok_or_else(|| ExtensionHostError::invalid_params("Expected an object"))?;
    let after = match input.get("after") {
        None | Some(Value::Null) => None,
        Some(Value::String(cursor))
            if !cursor.is_empty() && cursor.chars().count() <= MAX_CURSOR_CHARS =>
        {
            Some(cursor.clone())
        }
        Some(_) => {
            return Err(ExtensionHostError::invalid_params(
                "after cursor is invalid",
            ));
        }
    };
    let limit = match input.get("limit") {
        None | Some(Value::Null) => Some(DEFAULT_PAGE_LIMIT),
        Some(Value::Number(number)) => number
            .as_u64()
            .and_then(|limit| u32::try_from(limit).ok())
            .filter(|limit| (1..=MAX_PAGE_LIMIT).contains(limit)),
        Some(_) => None,
    }
    .ok_or_else(|| {
        ExtensionHostError::invalid_params(format!(
            "limit must be an integer from 1 to {MAX_PAGE_LIMIT}"
        ))
    })?;
    Ok(SessionPageRequest { after, limit })
}

/// One session as an extension sees it.
#[derive(Debug, Clone, PartialEq)]
pub struct ExtensionSessionRow {
    /// Id.
    pub id: String,
    /// Title, cut to 256 characters; `None` before the server names it.
    pub title: Option<String>,
    /// The title is the client's placeholder, not the server's.
    pub title_provisional: bool,
    /// `idle`, `running`, `waiting` or `failed`.
    pub status: String,
    /// A finished turn the caller has not seen.
    pub unread: bool,
    /// Workspace, cut to 512 characters.
    pub workspace: Option<String>,
    /// Git branch, cut to 256 characters.
    pub git_branch: Option<String>,
    /// Project id.
    pub project_id: Option<String>,
    /// Created, as the server stamps it.
    pub created_at: f64,
    /// Last changed, as the server stamps it.
    pub updated_at: f64,
}

impl ExtensionSessionRow {
    fn to_value(&self) -> Value {
        json!({
            "id": self.id,
            "title": self.title,
            "titleProvisional": self.title_provisional,
            "status": self.status,
            "unread": self.unread,
            "workspace": self.workspace,
            "gitBranch": self.git_branch,
            "projectId": self.project_id,
            "createdAt": self.created_at,
            "updatedAt": self.updated_at,
        })
    }
}

/// A page of the server's session list.
#[derive(Debug, Clone, PartialEq)]
pub struct SessionRows {
    /// The sessions, newest change first; none is unread yet.
    pub rows: Vec<ExtensionSessionRow>,
    /// More follow.
    pub has_more: bool,
    /// Where the next page starts, when the server says.
    pub last_id: Option<String>,
}

/// The rows of a `GET /v1/sessions` page asked with `limit`.
///
/// # Errors
///
/// `HostError` naming the first malformed part.
pub fn decode_session_rows(value: &Value, limit: u32) -> Result<SessionRows, ExtensionHostError> {
    let page = value
        .as_object()
        .ok_or_else(|| ExtensionHostError::host("Session list response is malformed"))?;
    let data = match page.get("data") {
        Some(Value::Array(data)) if u32::try_from(data.len()).is_ok_and(|count| count <= limit) => {
            data
        }
        _ => {
            return Err(ExtensionHostError::host(
                "Session list response is malformed",
            ));
        }
    };
    let Some(Value::Bool(has_more)) = page.get("has_more") else {
        return Err(ExtensionHostError::host("Session pagination is malformed"));
    };
    let last_id = match page.get("last_id") {
        None | Some(Value::Null) => None,
        Some(Value::String(cursor))
            if !cursor.is_empty() && cursor.chars().count() <= MAX_CURSOR_CHARS =>
        {
            Some(cursor.clone())
        }
        Some(_) => return Err(ExtensionHostError::host("Session cursor is malformed")),
    };
    let rows = data.iter().map(session_row).collect::<Result<_, _>>()?;
    Ok(SessionRows {
        rows,
        has_more: *has_more,
        last_id,
    })
}

fn session_row(value: &Value) -> Result<ExtensionSessionRow, ExtensionHostError> {
    let row = value
        .as_object()
        .ok_or_else(|| ExtensionHostError::host("Session row is malformed"))?;
    let id = match row.get("id") {
        Some(Value::String(id)) if !id.is_empty() && id.chars().count() <= MAX_ID_CHARS => {
            id.clone()
        }
        _ => return Err(ExtensionHostError::host("Session id is malformed")),
    };
    let status = match row.get("status") {
        Some(Value::String(status)) if STATUSES.contains(&status.as_str()) => status.clone(),
        _ => return Err(ExtensionHostError::host("Session status is malformed")),
    };
    let stamp = |key: &str| {
        row.get(key)
            .and_then(Value::as_f64)
            .filter(|stamp| stamp.is_finite())
            .ok_or_else(|| ExtensionHostError::host(format!("Session {key} is malformed")))
    };
    Ok(ExtensionSessionRow {
        created_at: stamp("created_at")?,
        updated_at: stamp("updated_at")?,
        title: bounded_text(row, "title", MAX_TITLE_CHARS)?,
        title_provisional: false,
        workspace: bounded_text(row, "workspace", MAX_WORKSPACE_CHARS)?,
        git_branch: bounded_text(row, "git_branch", MAX_TITLE_CHARS)?,
        project_id: bounded_text(row, "project_id", MAX_ID_CHARS)?,
        unread: false,
        id,
        status,
    })
}

fn bounded_text(
    row: &Map<String, Value>,
    key: &str,
    limit: usize,
) -> Result<Option<String>, ExtensionHostError> {
    match row.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(bounded(text, limit))),
        Some(_) => Err(ExtensionHostError::host(format!(
            "Session {key} is malformed"
        ))),
    }
}

fn page_value(
    rows: &[ExtensionSessionRow],
    count: usize,
    more: bool,
    cursor: Option<&str>,
) -> Value {
    let shown = rows.get(..count).unwrap_or(rows);
    let truncated = count < rows.len();
    let has_more = truncated || more;
    let next_cursor = if !has_more {
        None
    } else if truncated {
        shown.last().map(|row| row.id.clone())
    } else {
        cursor
            .map(str::to_owned)
            .or_else(|| shown.last().map(|row| row.id.clone()))
    };
    json!({
        "sessions": shown.iter().map(ExtensionSessionRow::to_value).collect::<Vec<_>>(),
        "nextCursor": next_cursor,
        "hasMore": has_more,
    })
}

/// `sessions.listPage`'s answer: `{sessions, nextCursor, hasMore}`. A page over the session page
/// budget keeps as many leading sessions as fit and continues after the last one kept.
///
/// # Errors
///
/// `HostError` when not even one session fits, or more follow and nothing says where.
pub fn session_page_result(page: &SessionRows) -> Result<Value, ExtensionHostError> {
    let rows = &page.rows;
    let cursor = page.last_id.as_deref();
    let no_cursor = || ExtensionHostError::host("Session list has more pages but no cursor");
    let missing_cursor = |value: &Value| {
        value.get("hasMore") == Some(&Value::Bool(true))
            && value.get("nextCursor").is_none_or(Value::is_null)
    };
    let full = page_value(rows, rows.len(), page.has_more, cursor);
    if rows.is_empty() {
        return if missing_cursor(&full) {
            Err(no_cursor())
        } else {
            Ok(full)
        };
    }
    if within_budget(&full, true) {
        return Ok(full);
    }
    // The cursor counts at its longest, so the kept page fits whatever cursor it ends with.
    let longest_cursor = "x".repeat(MAX_CURSOR_CHARS);
    let (mut lower, mut upper) = (1, rows.len().saturating_sub(1));
    let mut best = None;
    while lower <= upper {
        let count = lower + (upper - lower) / 2;
        let mut probe = page_value(rows, count, page.has_more, cursor);
        if let Some(object) = probe.as_object_mut() {
            object.insert("nextCursor".into(), json!(longest_cursor));
        }
        if within_budget(&probe, true) {
            best = Some(count);
            lower = count + 1;
        } else {
            upper = count - 1;
        }
    }
    let count =
        best.ok_or_else(|| ExtensionHostError::host("Session page exceeds the response budget"))?;
    let result = page_value(rows, count, page.has_more, cursor);
    if missing_cursor(&result) {
        return Err(no_cursor());
    }
    Ok(result)
}

/// `sessions.getCached`'s answer: the first `limit` of the sessions the app already lists, or
/// `null` when they don't fit the budget.
#[must_use]
pub fn cached_sessions_result(rows: &[ExtensionSessionRow], limit: u32) -> Value {
    let count = usize::try_from(limit).map_or(rows.len(), |limit| limit.min(rows.len()));
    let shown = rows.get(..count).unwrap_or(rows).to_vec();
    let page = SessionRows {
        rows: shown,
        has_more: false,
        last_id: None,
    };
    session_page_result(&page)
        .ok()
        .and_then(|value| value.get("sessions").cloned())
        .unwrap_or(Value::Null)
}
