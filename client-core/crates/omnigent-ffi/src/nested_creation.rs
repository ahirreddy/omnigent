//! Add nested agent: a new, independent session in the same family as a source session.
//!
//! The composer's hosts under the server's destination policy, its validation, the source read
//! fresh, and `POST /v1/sessions` with `sibling_source_id`. The rules are
//! `omnigent_core::nested_creation`'s; the REST calls are the core client's.

use omnigent_core::creation as creation_core;
use omnigent_core::nested_creation as core;

use crate::client::ClientCore;
use crate::configuration::ModelChoice;
use crate::creation::{
    CreatedSession, CreationCatalog, CreationReceipt, CreationSelection, SandboxTarget,
};
use crate::errors::CoreError;
use crate::sessions::SessionSummary;

/// What the Add nested agent composer offers.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, uniffi::Record)]
pub struct NestedHostChoices {
    /// The hosts it may start on, in the catalog's order: ordinary hosts and the source's own
    /// sandbox host, or only the source's host unless the policy is `any_host`.
    pub host_ids: Vec<String>,
    /// "New sandbox" rows are offered.
    pub offers_new_sandbox: bool,
    /// "Connect a host" is offered.
    pub offers_connect_host: bool,
}

/// The sibling fields of one nested create.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, uniffi::Record)]
pub struct NestedRequest {
    /// The session the new one starts beside.
    pub source_id: String,
    /// The source's host: its sandbox may be reused, and the policy always allows it.
    pub source_host_id: Option<String>,
    /// A fresh token for the `omnigent.client_create_token` label.
    pub client_token: String,
}

impl From<NestedRequest> for core::NestedRequest {
    fn from(request: NestedRequest) -> Self {
        Self {
            source_id: request.source_id,
            source_host_id: request.source_host_id,
            client_token: request.client_token,
        }
    }
}

/// The label a nested create carries, so a list row that arrives first is recognised.
#[must_use]
#[uniffi::export]
pub fn client_create_token_label() -> String {
    core::CLIENT_CREATE_TOKEN_LABEL.to_owned()
}

/// What the composer offers for a source on `source_host_id` under `catalog`'s policy.
#[must_use]
#[uniffi::export]
pub fn nested_host_choices(
    catalog: CreationCatalog,
    source_host_id: Option<String>,
) -> NestedHostChoices {
    let choices = core::NestedHostChoices::new(
        &creation_core::CreationCatalog::from(catalog),
        source_host_id.as_deref(),
    );
    NestedHostChoices {
        host_ids: choices.host_ids,
        offers_new_sandbox: choices.offers_new_sandbox,
        offers_connect_host: choices.offers_connect_host,
    }
}

/// Why `agent_id` cannot start as a nested agent on `host_id`, or `None` when it can; the
/// source's own sandbox host is allowed.
#[must_use]
#[uniffi::export]
pub fn nested_unavailable_reason(
    catalog: CreationCatalog,
    agent_id: String,
    host_id: String,
    source_host_id: Option<String>,
) -> Option<String> {
    creation_core::CreationCatalog::from(catalog).nested_unavailable_reason(
        &agent_id,
        &host_id,
        source_host_id.as_deref(),
    )
}

/// Why a nested agent on `selection`'s host cannot be created with the host's advertised
/// `models`, or `None` when it can: the capability, the policy, then the ordinary checks.
#[must_use]
#[uniffi::export]
pub fn nested_creation_validation_error(
    catalog: CreationCatalog,
    selection: CreationSelection,
    models: Vec<ModelChoice>,
    source_host_id: Option<String>,
) -> Option<String> {
    let models: Vec<omnigent_core::config::session::ModelChoice> =
        models.into_iter().map(Into::into).collect();
    creation_core::CreationCatalog::from(catalog)
        .validate_nested(&selection.into(), &models, source_host_id.as_deref())
        .err()
        .map(|error| error.to_string())
}

#[uniffi::export]
impl ClientCore {
    /// The source of an Add nested agent composer, read fresh for its title, host, folder and
    /// branch.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, `SessionNotFound` and the read errors.
    pub async fn nested_source(&self, session_id: String) -> Result<SessionSummary, CoreError> {
        self.sessions()
            .nested_source(&session_id)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Creates a nested agent on `selection`'s host. `first_message` only lets Smart Routing
    /// pick a native pane's model; send it with `send_first_message`. Never retried.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: kind `Creation` for an unavailable selection (nothing sent), a
    /// refusal (the server's `400`, `403` or `409` in clear words) or an uncertain outcome;
    /// `InvalidIdentifier`; `Unauthorized`; the catalog read errors.
    pub async fn create_nested_session(
        &self,
        selection: CreationSelection,
        request: NestedRequest,
        title: String,
        first_message: Option<String>,
    ) -> Result<CreationReceipt, CoreError> {
        self.sessions()
            .create_nested_session(
                &selection.into(),
                &request.into(),
                &title,
                first_message.as_deref(),
            )
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Creates a nested agent, then sends `text` to it. Once the session exists this returns
    /// `Ok`, with a failed first message in `first_message`.
    ///
    /// # Errors
    ///
    /// As [`Self::create_nested_session`].
    pub async fn create_nested_session_and_send(
        &self,
        selection: CreationSelection,
        request: NestedRequest,
        title: String,
        text: String,
    ) -> Result<CreatedSession, CoreError> {
        self.sessions()
            .create_nested_session_and_send(&selection.into(), &request.into(), &title, &text)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Creates a nested agent on a new sandbox as `target` describes. Never retried.
    ///
    /// # Errors
    ///
    /// As [`Self::create_nested_session`].
    pub async fn create_nested_sandbox_session(
        &self,
        selection: CreationSelection,
        target: SandboxTarget,
        request: NestedRequest,
        title: String,
    ) -> Result<CreationReceipt, CoreError> {
        let target = creation_core::SandboxTarget {
            provider: target.provider,
            profile: target.profile.map(|profile| (profile.id, profile.revision)),
            workspaces: target.workspaces,
            // Sent only to servers that ask clients to name a new sandbox's host.
            host_id: Some(self.random_host_id()?),
        };
        self.sessions()
            .create_nested_sandbox_session(&selection.into(), &target, &request.into(), &title)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }
}
