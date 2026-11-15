//! Add nested agent: a new, independent session in the same family as a source session.
//!
//! The rules are the web's `NewChatDialog` in sibling mode and the server's
//! `session_families.require_sibling_destination`:
//!
//! - The composer offers the ordinary (non-sandbox) hosts plus the source's own sandbox host.
//!   Unless the policy is `any_host`, only the source's host is offered.
//! - "New sandbox" is offered unless the policy is `current_host`, and only when the server
//!   provisions sandboxes. "Connect a host" only with `any_host`.
//! - The request is the normal `POST /v1/sessions` plus `sibling_source_id`, never
//!   `project_id`, `initial_items` or `parent_session_id`, with the
//!   `omnigent.client_create_token` label so a list row that arrives before the response is
//!   recognised as this create's.

use serde_json::{Map, Value};

use crate::config::session::ModelChoice;
use crate::creation::{
    CreationAgent, CreationCatalog, CreationError, CreationSelection, SandboxTarget, creation_body,
    creation_rejection, sandbox_creation_body,
};
use crate::session_families::SiblingDestinations;

/// The label that ties a create to the list row the server pushes for it.
pub const CLIENT_CREATE_TOKEN_LABEL: &str = "omnigent.client_create_token";

/// Where a nested agent would start, for the policy check.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NestedDestination<'a> {
    /// An existing host, by id.
    Host(&'a str),
    /// A new managed sandbox.
    NewSandbox,
}

/// Why `policy` refuses `destination` for a source on `source_host_id`, in the server's words;
/// `None` when it is allowed.
#[must_use]
pub fn destination_refusal(
    policy: SiblingDestinations,
    source_host_id: Option<&str>,
    destination: NestedDestination<'_>,
) -> Option<String> {
    let to_source =
        matches!(destination, NestedDestination::Host(host_id) if Some(host_id) == source_host_id);
    match (policy, destination) {
        (SiblingDestinations::AnyHost, _)
        | (SiblingDestinations::CurrentHostOrNewSandbox, NestedDestination::NewSandbox) => None,
        _ if to_source => None,
        (SiblingDestinations::CurrentHost, _) => {
            Some("Add nested agent is limited to the current host by server policy.".to_owned())
        }
        (SiblingDestinations::CurrentHostOrNewSandbox, NestedDestination::Host(_)) => Some(
            "Add nested agent is limited to the current host or a new managed sandbox by server \
             policy."
                .to_owned(),
        ),
    }
}

/// What the Add nested agent composer offers.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NestedHostChoices {
    /// The hosts it may start on, in the catalog's order.
    pub host_ids: Vec<String>,
    /// "New sandbox" rows are offered.
    pub offers_new_sandbox: bool,
    /// "Connect a host" is offered.
    pub offers_connect_host: bool,
}

impl NestedHostChoices {
    /// The choices `catalog`'s policy leaves for a source on `source_host_id`.
    #[must_use]
    pub fn new(catalog: &CreationCatalog, source_host_id: Option<&str>) -> Self {
        let policy = catalog.capabilities.sibling_destinations;
        let host_ids = catalog
            .hosts
            .iter()
            .filter(|host| {
                let is_source = Some(host.host_id.as_str()) == source_host_id;
                (host.sandbox_provider.is_none() || is_source)
                    && destination_refusal(
                        policy,
                        source_host_id,
                        NestedDestination::Host(&host.host_id),
                    )
                    .is_none()
            })
            .map(|host| host.host_id.clone())
            .collect();
        Self {
            host_ids,
            offers_new_sandbox: !catalog.capabilities.sandbox_provider_options().is_empty()
                && destination_refusal(policy, source_host_id, NestedDestination::NewSandbox)
                    .is_none(),
            offers_connect_host: policy == SiblingDestinations::AnyHost,
        }
    }

    /// Whether `host_id` is offered.
    #[must_use]
    pub fn allows_host(&self, host_id: &str) -> bool {
        self.host_ids.iter().any(|offered| offered == host_id)
    }
}

/// The sibling fields of one nested create.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NestedRequest {
    /// The session the new one starts beside.
    pub source_id: String,
    /// The source's host, whose sandbox may be reused and which the policy always allows.
    pub source_host_id: Option<String>,
    /// A fresh token for [`CLIENT_CREATE_TOKEN_LABEL`].
    pub client_token: String,
}

impl CreationCatalog {
    /// Why `agent_id` cannot start as a nested agent on `host_id`, or `None` when it can: as
    /// [`Self::unavailable_reason`], except that the source's own sandbox host is allowed.
    #[must_use]
    pub fn nested_unavailable_reason(
        &self,
        agent_id: &str,
        host_id: &str,
        source_host_id: Option<&str>,
    ) -> Option<String> {
        self.host_unavailable_reason(agent_id, host_id, source_host_id)
    }

    /// Checks a nested agent on an existing host: the capability, the policy, then
    /// [`Self::validate`] with the source's sandbox host allowed.
    ///
    /// # Errors
    ///
    /// [`CreationError::Unavailable`] with the reason.
    pub fn validate_nested(
        &self,
        selection: &CreationSelection,
        models: &[ModelChoice],
        source_host_id: Option<&str>,
    ) -> Result<(), CreationError> {
        self.nested_offered(source_host_id, NestedDestination::Host(&selection.host_id))?;
        self.validate_on(selection, models, source_host_id)
    }

    /// Checks a nested agent on a new sandbox: the capability, the policy, then
    /// [`Self::validate_sandbox`].
    ///
    /// # Errors
    ///
    /// [`CreationError::Unavailable`] with the reason.
    pub fn validate_nested_sandbox(
        &self,
        selection: &CreationSelection,
        target: &SandboxTarget,
        source_host_id: Option<&str>,
    ) -> Result<(), CreationError> {
        self.nested_offered(source_host_id, NestedDestination::NewSandbox)?;
        self.validate_sandbox(selection, target)
    }

    fn nested_offered(
        &self,
        source_host_id: Option<&str>,
        destination: NestedDestination<'_>,
    ) -> Result<(), CreationError> {
        if !self.capabilities.sibling_sessions {
            return Err(CreationError::Unavailable(
                NESTED_AGENTS_UNAVAILABLE.to_owned(),
            ));
        }
        destination_refusal(
            self.capabilities.sibling_destinations,
            source_host_id,
            destination,
        )
        .map_or(Ok(()), |reason| Err(CreationError::Unavailable(reason)))
    }
}

/// What the composer says on a server without nested agents.
pub const NESTED_AGENTS_UNAVAILABLE: &str = "Nested agents are not available on this server.";

/// The `POST /v1/sessions` body of a nested agent on an existing host: the external create
/// with `sibling_source_id` and the token label, and never a project.
pub(crate) fn nested_creation_body(
    selection: &CreationSelection,
    title: &str,
    agent: &CreationAgent,
    first_message: Option<&str>,
    request: &NestedRequest,
) -> Value {
    let unfiled = CreationSelection {
        project_id: None,
        ..selection.clone()
    };
    with_sibling_fields(
        creation_body(&unfiled, title, agent, first_message),
        request,
    )
}

/// The `POST /v1/sessions` body of a nested agent on a new sandbox. The workspace and git
/// block are pinned to null: the server files it in the source's project, whose configured
/// folder or worktree a managed create would refuse.
pub(crate) fn nested_sandbox_creation_body(
    selection: &CreationSelection,
    target: &SandboxTarget,
    title: &str,
    agent: &CreationAgent,
    request: &NestedRequest,
) -> Value {
    let unfiled = CreationSelection {
        project_id: None,
        ..selection.clone()
    };
    let mut body = with_sibling_fields(
        sandbox_creation_body(&unfiled, target, title, agent),
        request,
    );
    if let Value::Object(object) = &mut body {
        object.insert("workspace".into(), Value::Null);
        object.insert("git".into(), Value::Null);
    }
    body
}

fn with_sibling_fields(body: Value, request: &NestedRequest) -> Value {
    let Value::Object(mut object) = body else {
        return body;
    };
    object.insert(
        "sibling_source_id".into(),
        Value::String(request.source_id.clone()),
    );
    let mut labels = match object.remove("labels") {
        Some(Value::Object(labels)) => labels,
        _ => Map::new(),
    };
    labels.insert(
        CLIENT_CREATE_TOKEN_LABEL.into(),
        Value::String(request.client_token.clone()),
    );
    object.insert("labels".into(), Value::Object(labels));
    Value::Object(object)
}

/// The server's refusal of a nested create (`403`, `400` or `409`), in words for the composer.
pub(crate) fn nested_rejection(body: &[u8], status: u16) -> String {
    let server = creation_rejection(body, status);
    let known = [
        ("Nested agents are disabled", NESTED_AGENTS_UNAVAILABLE),
        (
            "Session is not owned or available",
            "Only the owner of an active session can add a nested agent to it.",
        ),
        (
            "shared with edit access",
            "A session shared with edit access can't have nested agents.",
        ),
        (
            "Sibling source is no longer available",
            "The source session is no longer available. Nothing was created.",
        ),
        (
            "still used by another family",
            "The source session already belongs to another group. Nothing was created.",
        ),
        (
            "Siblings require an owned source",
            "Only the owner of an active session can add a nested agent to it.",
        ),
    ];
    known
        .iter()
        .find(|(phrase, _)| server.contains(phrase))
        .map_or(server, |(_, text)| (*text).to_owned())
}

#[cfg(test)]
#[path = "nested_creation_tests.rs"]
mod tests;
