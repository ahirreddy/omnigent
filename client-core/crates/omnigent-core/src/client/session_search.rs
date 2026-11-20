//! Server-side session search (`GET /v1/sessions?search_query=`), for the command palette's
//! title matches beyond the loaded list and its "In messages" group.

use omnigent_protocol::FromWire;
use omnigent_protocol::sessions::SessionList;

use super::requests::page_query;
use super::sessions::{SessionProjection, SessionSummary};
use super::{ClientCore, SessionError, lock};
use crate::http::HttpTransport;

/// Which matches a search returns.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SearchScope {
    /// Title matches.
    Title,
    /// Message content matches; the preview is the matching snippet.
    Content,
}

impl SearchScope {
    const fn wire(self) -> &'static str {
        match self {
            Self::Title => "title",
            Self::Content => "content",
        }
    }
}

impl<T: HttpTransport> ClientCore<T> {
    /// The first `limit` sessions matching `query` in `scope`, archived included, most recent
    /// first. The results are not cached, so a snippet never replaces a list row's preview.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidPageLimit`] before any request; the read errors;
    /// [`SessionError::MalformedResponse`]. A blank query returns nothing without a request.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn search_sessions(
        &self,
        query: &str,
        scope: SearchScope,
        limit: u32,
    ) -> Result<Vec<SessionSummary>, SessionError> {
        let result = self.search(query, scope, true, None, limit).await;
        self.dispatch();
        result.map(|page| page.sessions)
    }

    /// The page after `after` (the first when `None`) of up to `limit` sessions matching
    /// `query` in `scope`, archived ones only when `include_archived`, most recent first.
    ///
    /// # Errors
    ///
    /// [`SessionError::InvalidPageLimit`] and [`SessionError::InvalidPagination`] before any
    /// request; the read errors; [`SessionError::MalformedResponse`]. A blank query returns an
    /// empty last page without a request.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn search_session_page(
        &self,
        query: &str,
        scope: SearchScope,
        include_archived: bool,
        after: Option<&str>,
        limit: u32,
    ) -> Result<SessionSearchPage, SessionError> {
        let result = self
            .search(query, scope, include_archived, after, limit)
            .await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn search(
        &self,
        query: &str,
        scope: SearchScope,
        include_archived: bool,
        after: Option<&str>,
        limit: u32,
    ) -> Result<SessionSearchPage, SessionError> {
        let query = query.trim();
        let mut parameters = page_query(after, limit)?;
        if query.is_empty() {
            return Ok(SessionSearchPage::default());
        }
        parameters.push(("sort_by", "updated_at".to_owned()));
        parameters.push(("include_archived", include_archived.to_string()));
        parameters.push(("visibility", "all".to_owned()));
        parameters.push(("search_query", query.to_owned()));
        parameters.push(("search_scope", scope.wire().to_owned()));
        let response = self
            .read(self.prepare("GET", "/v1/sessions", &parameters, None)?)
            .await?;
        let page = SessionList::from_json(&response.body).map_err(|error| {
            SessionError::MalformedResponse {
                detail: format!("/v1/sessions?search_query: {error}"),
            }
        })?;
        let state = lock(&self.state);
        let sessions = page
            .data
            .iter()
            .map(|row| {
                SessionProjection::from_list_item(row)
                    .summary(state.summaries.get(&row.id))
                    .map_err(|detail| SessionError::MalformedResponse { detail })
            })
            .collect::<Result<Vec<_>, _>>()?;
        let next_cursor = page
            .last_id
            .filter(|cursor| page.has_more && !cursor.is_empty());
        Ok(SessionSearchPage {
            sessions,
            next_cursor,
        })
    }
}

/// One page of a session search.
#[derive(Debug, Clone, Default)]
pub struct SessionSearchPage {
    /// The matches, most recent first.
    pub sessions: Vec<SessionSummary>,
    /// The `after` cursor of the next page; `None` on the last.
    pub next_cursor: Option<String>,
}

#[cfg(test)]
mod tests {
    use futures::executor::block_on;

    use super::SearchScope;
    use crate::client::test_support::{RouteTransport, connected, path_of, query_value};

    #[test]
    fn a_title_search_says_so_and_an_unreadable_list_is_reported() {
        let transport = RouteTransport::local();
        transport.ok("/v1/sessions", "[5]");
        let core = connected(transport);
        assert!(matches!(
            block_on(core.search_sessions("x", SearchScope::Title, 10)),
            Err(crate::client::SessionError::MalformedResponse { detail })
                if detail.contains("search_query")
        ));
        let request = core.transport().taken().pop().unwrap();
        assert_eq!(path_of(&request), "/v1/sessions");
        assert_eq!(
            query_value(&request, "search_scope").as_deref(),
            Some("title")
        );
    }

    #[test]
    fn content_search_sends_the_scope_and_keeps_the_snippet() {
        let transport = RouteTransport::local();
        transport.ok(
            "/v1/sessions",
            r#"{"data":[{"id":"a","status":"idle","created_at":1,"title":"Deploy","search_snippet":"...the rollout..."}],"has_more":false}"#,
        );
        let core = connected(transport);
        let found = block_on(core.search_sessions(" rollout ", SearchScope::Content, 10)).unwrap();
        assert_eq!(found[0].preview, "...the rollout...");
        let request = core
            .transport()
            .taken()
            .into_iter()
            .rfind(|request| path_of(request) == "/v1/sessions")
            .unwrap();
        assert_eq!(
            query_value(&request, "search_query").as_deref(),
            Some("rollout")
        );
        assert_eq!(
            query_value(&request, "search_scope").as_deref(),
            Some("content")
        );
        let before = core.transport().taken().len();
        assert_eq!(
            block_on(core.search_sessions("  ", SearchScope::Title, 10)),
            Ok(vec![])
        );
        assert_eq!(core.transport().taken().len(), before);
    }

    #[test]
    fn a_search_page_leaves_archived_out_when_asked_and_names_the_next_page() {
        let transport = RouteTransport::local();
        transport.ok(
            "/v1/sessions",
            r#"{"data":[{"id":"a","status":"idle","created_at":1,"title":"Lead"}],"has_more":true,"last_id":"a"}"#,
        );
        let core = connected(transport);
        let page =
            block_on(core.search_session_page("lead", SearchScope::Title, false, Some("z"), 20))
                .unwrap();
        assert_eq!(page.sessions.len(), 1);
        assert_eq!(page.next_cursor.as_deref(), Some("a"));
        let request = core
            .transport()
            .taken()
            .into_iter()
            .rfind(|request| path_of(request) == "/v1/sessions")
            .unwrap();
        assert_eq!(
            query_value(&request, "include_archived").as_deref(),
            Some("false")
        );
        assert_eq!(query_value(&request, "after").as_deref(), Some("z"));
        assert_eq!(query_value(&request, "limit").as_deref(), Some("20"));
        assert!(matches!(
            block_on(core.search_session_page("lead", SearchScope::Title, false, Some(""), 20)),
            Err(crate::client::SessionError::InvalidPagination)
        ));
    }
}
