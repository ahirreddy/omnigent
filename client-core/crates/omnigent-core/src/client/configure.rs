//! Session configuration over REST: model and effort `PATCH`es and in-place harness switches.
//!
//! Port of `NativeLab`'s `LocalServerConfiguration.swift`. The rules:
//!
//! - A configuration read whose session metadata changed while it was in flight (a settings or
//!   turn event, or a list row) fails [`ConfigurationError::ChangedElsewhere`] instead of
//!   rolling the newer state back.
//! - A change is only attempted on an idle, editable, unarchived session whose live stream is
//!   open and whose host or runner is online. One change per session at a time.
//! - Model then effort, one `PATCH` each, re-reading in between; a reset sends the `default`
//!   sentinel. A `PATCH` acknowledgement that does not show the requested value, or arrives
//!   after a crossing event and is contradicted by a fresh read, is
//!   [`SessionError::DeliveryUncertain`]. If the model was saved and the effort then fails, the
//!   whole change is uncertain so a saved model never looks rolled back.
//! - A harness switch posts `switch-agent` and must be acknowledged by a different agent on the
//!   target harness, on the same session.

use std::collections::BTreeSet;

use serde_json::{Map, Value};

use super::requests::validate_identifier;
use super::sessions::{SessionSummary, SummaryStatus, decode_snapshot_value};
use super::{ClientCore, ClientEvent, SessionError, lock};
use crate::config::session::{
    ConfigurationCatalog, ConfigurationEdit, ConfigurationError, ConfigurationHost, HarnessChoice,
    ModelChoice, SessionConfiguration, canonical_harness,
};
use crate::http::HttpTransport;

/// Removes the session from the in-flight configuration set when dropped.
struct MutationGuard<'a, T> {
    core: &'a ClientCore<T>,
    session_id: String,
}

impl<T> Drop for MutationGuard<'_, T> {
    fn drop(&mut self) {
        lock(&self.core.state)
            .configuration_mutations
            .remove(&self.session_id);
    }
}

fn unavailable(text: &str) -> SessionError {
    ConfigurationError::Unavailable(text.to_owned()).into()
}

fn uncertain(detail: impl Into<String>) -> SessionError {
    SessionError::DeliveryUncertain {
        detail: detail.into(),
    }
}

/// Whether `actual` shows `expected` as its model override (directly, or through an option that
/// matches both).
fn model_acknowledged(expected: Option<&str>, actual: &SessionConfiguration) -> bool {
    if actual.model_override.as_deref() == expected {
        return true;
    }
    let (Some(expected), Some(current)) = (expected, actual.model_override.as_deref()) else {
        return false;
    };
    actual
        .models
        .iter()
        .any(|choice| choice.matches(Some(expected)) && choice.matches(Some(current)))
}

impl<T: HttpTransport> ClientCore<T> {
    fn begin_mutation(&self, session_id: &str) -> Result<MutationGuard<'_, T>, SessionError> {
        if !lock(&self.state)
            .configuration_mutations
            .insert(session_id.to_owned())
        {
            return Err(SessionError::Busy);
        }
        Ok(MutationGuard {
            core: self,
            session_id: session_id.to_owned(),
        })
    }

    /// A fresh summary of `session_id` for the settings sheet.
    ///
    /// # Errors
    ///
    /// The read errors, and [`ConfigurationError::ChangedElsewhere`] when the session's metadata
    /// changed while the read was in flight (the newer cached state is kept).
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn configuration_snapshot(
        &self,
        session_id: &str,
    ) -> Result<SessionSummary, SessionError> {
        let result = self.config_snapshot(session_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn config_snapshot(&self, session_id: &str) -> Result<SessionSummary, SessionError> {
        let (decoded, epoch) = self.fetch_snapshot(session_id).await?;
        let mut state = lock(&self.state);
        if state.metadata_epoch(session_id) != epoch {
            return Err(ConfigurationError::ChangedElsewhere.into());
        }
        let summary = decoded
            .projection
            .summary(state.summaries.get(session_id))
            .map_err(|detail| SessionError::MalformedResponse { detail })?;
        Ok(Self::accept_configuration(&mut state, summary))
    }

    fn accept_configuration(state: &mut super::State, summary: SessionSummary) -> SessionSummary {
        let summary = state.record_summary(summary);
        state.cache_summary(&summary);
        state.events.push(ClientEvent::SessionsChanged {
            sessions: vec![summary.clone()],
        });
        summary
    }

    /// What `session_id` may switch to, its host, and (when the runner reported no models) the
    /// host's model preview. A failed preview is recorded in
    /// [`ConfigurationCatalog::model_options_error`] and never hides the harness catalog.
    ///
    /// # Errors
    ///
    /// The snapshot, hosts and agents read errors; a `401` on the preview.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn configuration_catalog(
        &self,
        session_id: &str,
    ) -> Result<ConfigurationCatalog, SessionError> {
        let result = self.config_catalog(session_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn config_catalog(&self, session_id: &str) -> Result<ConfigurationCatalog, SessionError> {
        let summary = self.config_snapshot(session_id).await?;
        let malformed = |detail: String| SessionError::MalformedResponse { detail };
        let hosts = self
            .host_rows()
            .await?
            .iter()
            .map(ConfigurationHost::from_value)
            .collect::<Result<Vec<_>, String>>()
            .map_err(malformed)?;
        let agents = self
            .agent_rows()
            .await?
            .iter()
            .map(HarnessChoice::from_value)
            .collect::<Result<Vec<_>, String>>()
            .map_err(malformed)?;
        let mut seen = BTreeSet::new();
        let host_id = summary
            .configuration
            .as_ref()
            .and_then(|configuration| configuration.host_id.clone());
        let mut catalog = ConfigurationCatalog {
            agents: agents
                .into_iter()
                .filter(|agent| agent.builtin == Some(true) && seen.insert(agent.id.clone()))
                .collect(),
            host: hosts
                .into_iter()
                .find(|host| Some(&host.host_id) == host_id.as_ref()),
            ..ConfigurationCatalog::default()
        };
        if let Some(current) = summary.configuration
            && current.models.is_empty()
            && current.supports_models()
            && catalog
                .host
                .as_ref()
                .is_some_and(|host| host.status == "online")
        {
            match self.preview_models(&current).await {
                Ok(models) => {
                    catalog.model_options = models;
                    catalog.model_options_identity = Some(current);
                }
                Err(error @ SessionError::Unauthorized { .. }) => return Err(error),
                Err(error) => catalog.model_options_error = Some(error.to_string()),
            }
        }
        Ok(catalog)
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn preview_models(
        &self,
        configuration: &SessionConfiguration,
    ) -> Result<Vec<ModelChoice>, SessionError> {
        let host_id = configuration
            .host_id
            .as_deref()
            .filter(|_| configuration.host_online == Some(true) && configuration.supports_models())
            .ok_or_else(|| unavailable("The host must be online to preview model choices."))?;
        let harness = canonical_harness(configuration.harness.as_deref());
        self.host_model_options(host_id, &harness, false).await
    }

    fn mutation_allowed(&self, summary: &SessionSummary) -> Result<(), SessionError> {
        if summary.is_read_only {
            return Err(SessionError::ReadOnly);
        }
        if summary.is_archived {
            return Err(SessionError::Archived);
        }
        if summary.status != SummaryStatus::Idle {
            return Err(SessionError::Busy);
        }
        if lock(&self.state).live_session.as_deref() != Some(summary.id.as_str()) {
            return Err(SessionError::StreamNotReady);
        }
        let online = summary.configuration.as_ref().is_some_and(|configuration| {
            configuration.host_online == Some(true) || configuration.runner_online == Some(true)
        });
        if !online {
            return Err(unavailable(
                "Reconnect the session's host before changing settings.",
            ));
        }
        Ok(())
    }

    /// Applies `edit` to `session_id`: model first, then effort, one `PATCH` each.
    ///
    /// # Errors
    ///
    /// [`SessionError::Busy`] while another change for the session is in flight; the guards
    /// ([`SessionError::ReadOnly`], [`SessionError::Archived`], [`SessionError::Busy`],
    /// [`SessionError::StreamNotReady`], [`ConfigurationError::Unavailable`]); the validation
    /// errors; [`SessionError::DeliveryUncertain`] (see the [module docs](self)); the read and
    /// write errors.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn apply_configuration(
        &self,
        edit: &ConfigurationEdit,
        session_id: &str,
    ) -> Result<SessionSummary, SessionError> {
        let result = self.apply(edit, session_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn apply(
        &self,
        edit: &ConfigurationEdit,
        session_id: &str,
    ) -> Result<SessionSummary, SessionError> {
        validate_identifier(session_id)?;
        let _guard = self.begin_mutation(session_id)?;
        let summary = self.config_snapshot(session_id).await?;
        self.mutation_allowed(&summary)?;
        let mut current = summary
            .configuration
            .clone()
            .ok_or_else(|| unavailable("Settings are unavailable."))?;
        if current.models.is_empty() && edit.has_changes() && current.supports_models() {
            let epoch = lock(&self.state).metadata_epoch(session_id);
            current.models = self.preview_models(&current).await?;
            if lock(&self.state).metadata_epoch(session_id) != epoch {
                return Err(ConfigurationError::ChangedElsewhere.into());
            }
            self.mutation_allowed(&summary)?;
        }
        edit.validate(&current)?;
        let mut attempted = false;
        let mut saved_model = false;
        let result = self
            .apply_patches(
                edit,
                &current,
                summary,
                session_id,
                &mut attempted,
                &mut saved_model,
            )
            .await;
        if attempted {
            lock(&self.state).request_rehydration(session_id);
        }
        match result {
            Err(error)
                if saved_model && !matches!(error, SessionError::DeliveryUncertain { .. }) =>
            {
                Err(uncertain(format!(
                    "the model was saved but the effort change failed: {error}"
                )))
            }
            other => other,
        }
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn apply_patches(
        &self,
        edit: &ConfigurationEdit,
        current: &SessionConfiguration,
        mut summary: SessionSummary,
        session_id: &str,
        attempted: &mut bool,
        saved_model: &mut bool,
    ) -> Result<SessionSummary, SessionError> {
        if edit.model != current.model_override {
            *attempted = true;
            summary = self
                .patch_configuration(session_id, "model_override", edit.model.as_deref())
                .await?;
            *saved_model = true;
        }
        if edit.effort != current.effort {
            let latest = self.config_snapshot(session_id).await?;
            self.mutation_allowed(&latest)?;
            let consistent = match (&latest.configuration, &summary.configuration) {
                (Some(actual), Some(acknowledged)) => actual.same_selection(acknowledged),
                _ => false,
            };
            if !consistent {
                return Err(ConfigurationError::ChangedElsewhere.into());
            }
            *attempted = true;
            summary = self
                .patch_configuration(session_id, "reasoning_effort", edit.effort.as_deref())
                .await?;
        }
        Ok(summary)
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn patch_configuration(
        &self,
        session_id: &str,
        field: &str,
        value: Option<&str>,
    ) -> Result<SessionSummary, SessionError> {
        let epoch = lock(&self.state).metadata_epoch(session_id);
        let mut body = Map::new();
        body.insert(
            field.to_owned(),
            Value::String(value.unwrap_or("default").to_owned()),
        );
        let path = format!("/v1/sessions/{session_id}");
        let acknowledgement = self
            .write_json("PATCH", &path, &Value::Object(body))
            .await?;
        let decoded = decode_snapshot_value(acknowledgement)
            .map_err(|detail| uncertain(format!("unreadable PATCH acknowledgement: {detail}")))?;
        if decoded.snapshot.id != session_id {
            return Err(uncertain("the PATCH acknowledgement names another session"));
        }
        let fresh = lock(&self.state).metadata_epoch(session_id) == epoch;
        let summary = if fresh {
            let state = lock(&self.state);
            decoded
                .projection
                .summary(state.summaries.get(session_id))
                .map_err(uncertain)?
        } else {
            self.config_snapshot(session_id)
                .await
                .map_err(|error| uncertain(format!("re-read after a crossing event: {error}")))?
        };
        let acknowledged = summary.configuration.as_ref().is_some_and(|actual| {
            if field == "model_override" {
                model_acknowledged(value, actual)
            } else {
                actual.effort.as_deref() == value
            }
        });
        if !acknowledged {
            return Err(uncertain(format!("the server did not acknowledge {field}")));
        }
        Ok(Self::accept_configuration(&mut lock(&self.state), summary))
    }

    /// Switches `session_id` in place to the built-in agent `target_id`, keeping the session and
    /// its history. `baseline` is the configuration the user saw.
    ///
    /// # Errors
    ///
    /// [`SessionError::Busy`], the guards, [`ConfigurationError::ChangedElsewhere`] when the
    /// selection moved, [`ConfigurationError::Unavailable`] for a target that cannot be switched
    /// to, and [`SessionError::DeliveryUncertain`] when the acknowledgement does not show the
    /// target.
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn switch_harness(
        &self,
        target_id: &str,
        baseline: &SessionConfiguration,
        session_id: &str,
    ) -> Result<SessionSummary, SessionError> {
        let result = self.switch(target_id, baseline, session_id).await;
        self.dispatch();
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn switch(
        &self,
        target_id: &str,
        baseline: &SessionConfiguration,
        session_id: &str,
    ) -> Result<SessionSummary, SessionError> {
        validate_identifier(session_id)?;
        let _guard = self.begin_mutation(session_id)?;
        validate_identifier(target_id)?;
        let catalog = self.config_catalog(session_id).await?;
        let summary = self.config_snapshot(session_id).await?;
        self.mutation_allowed(&summary)?;
        let current = summary
            .configuration
            .clone()
            .filter(|current| baseline.same_selection(current))
            .ok_or(ConfigurationError::ChangedElsewhere)?;
        let target = catalog
            .agents
            .iter()
            .find(|agent| agent.id == target_id)
            .ok_or_else(|| unavailable("This harness is no longer in the server catalog."))?;
        if let Some(reason) = catalog.unavailable_reason(target, &current) {
            return Err(ConfigurationError::Unavailable(reason).into());
        }
        let result = self.post_switch(target, baseline, session_id).await;
        lock(&self.state).request_rehydration(session_id);
        result
    }

    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    async fn post_switch(
        &self,
        target: &HarnessChoice,
        baseline: &SessionConfiguration,
        session_id: &str,
    ) -> Result<SessionSummary, SessionError> {
        let epoch = lock(&self.state).metadata_epoch(session_id);
        let mut body = Map::new();
        body.insert("agent_id".into(), Value::String(target.id.clone()));
        let path = format!("/v1/sessions/{session_id}/switch-agent");
        let acknowledgement = self.write_json("POST", &path, &Value::Object(body)).await?;
        let decoded = decode_snapshot_value(acknowledgement)
            .map_err(|detail| uncertain(format!("unreadable switch acknowledgement: {detail}")))?;
        if decoded.snapshot.id != session_id {
            return Err(uncertain(
                "the switch acknowledgement names another session",
            ));
        }
        let fresh = lock(&self.state).metadata_epoch(session_id) == epoch;
        let updated = if fresh {
            decoded.projection.summary(None).map_err(uncertain)?
        } else {
            self.config_snapshot(session_id)
                .await
                .map_err(|error| uncertain(format!("re-read after a crossing event: {error}")))?
        };
        let switched = updated.configuration.as_ref().is_some_and(|actual| {
            actual.agent_id.is_some()
                && actual.agent_id != baseline.agent_id
                && canonical_harness(actual.harness.as_deref())
                    == canonical_harness(target.harness.as_deref())
        });
        if !switched {
            return Err(uncertain(
                "the server did not acknowledge the harness switch",
            ));
        }
        Ok(Self::accept_configuration(&mut lock(&self.state), updated))
    }
}
