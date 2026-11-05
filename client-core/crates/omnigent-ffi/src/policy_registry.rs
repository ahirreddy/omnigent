//! Adding default policies from the policy registry and inviting members
//! (`omnigent_core::policy_registry`).

use std::collections::{BTreeMap, HashMap};

use omnigent_core::policy_registry as core;

use crate::client::ClientCore;
use crate::errors::CoreError;
use crate::server_admin::DefaultPolicyRecord;

/// How a policy parameter is edited.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum PolicyParamKind {
    /// Free text.
    Text,
    /// A whole number.
    Integer,
    /// Any number.
    Number,
    /// `true` or `false`.
    Boolean,
    /// One of the options.
    Choice,
    /// A comma-separated list.
    List,
    /// Any of the options, comma-separated.
    MultiChoice,
    /// A JSON object.
    Object,
}

/// One parameter of a factory policy.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PolicyParam {
    /// The parameter name.
    pub key: String,
    /// How it is edited.
    pub kind: PolicyParamKind,
    /// What it does.
    pub description: Option<String>,
    /// The default as form text; empty when none.
    pub default_value: String,
    /// A choice's allowed values.
    pub options: Vec<String>,
    /// Required by the handler.
    pub required: bool,
}

/// A built-in policy handler.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PolicyRegistryEntry {
    /// The handler path, which identifies it.
    pub handler: String,
    /// Display name.
    pub name: String,
    /// What it does.
    pub description: String,
    /// Takes parameters.
    pub is_factory: bool,
    /// The parameters, by name.
    pub params: Vec<PolicyParam>,
    /// The name the add form suggests.
    pub suggested_name: String,
}

/// A minted member invite.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct MemberInvite {
    /// The register link to send.
    pub url: String,
    /// Expiry, Unix seconds.
    pub expires_at: Option<i64>,
    /// The account it creates is an administrator.
    pub is_admin: bool,
}

macro_rules! mirror_kind {
    ($from:path => $to:path) => {
        impl From<$from> for $to {
            fn from(kind: $from) -> Self {
                use $from as Source;
                match kind {
                    Source::Text => Self::Text,
                    Source::Integer => Self::Integer,
                    Source::Number => Self::Number,
                    Source::Boolean => Self::Boolean,
                    Source::Choice => Self::Choice,
                    Source::List => Self::List,
                    Source::MultiChoice => Self::MultiChoice,
                    Source::Object => Self::Object,
                }
            }
        }
    };
}

mirror_kind!(core::PolicyParamKind => PolicyParamKind);
mirror_kind!(PolicyParamKind => core::PolicyParamKind);

impl From<core::PolicyRegistryEntry> for PolicyRegistryEntry {
    fn from(entry: core::PolicyRegistryEntry) -> Self {
        let suggested_name = core::suggested_policy_name(&entry);
        Self {
            handler: entry.handler,
            name: entry.name,
            description: entry.description,
            is_factory: entry.is_factory,
            params: entry
                .params
                .into_iter()
                .map(|param| PolicyParam {
                    key: param.key,
                    kind: param.kind.into(),
                    description: param.description,
                    default_value: param.default_value,
                    options: param.options,
                    required: param.required,
                })
                .collect(),
            suggested_name,
        }
    }
}

impl From<PolicyRegistryEntry> for core::PolicyRegistryEntry {
    fn from(entry: PolicyRegistryEntry) -> Self {
        Self {
            handler: entry.handler,
            name: entry.name,
            description: entry.description,
            is_factory: entry.is_factory,
            params: entry
                .params
                .into_iter()
                .map(|param| core::PolicyParam {
                    key: param.key,
                    kind: param.kind.into(),
                    description: param.description,
                    default_value: param.default_value,
                    options: param.options,
                    required: param.required,
                })
                .collect(),
        }
    }
}

#[uniffi::export]
impl ClientCore {
    /// The built-in policy handlers.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors.
    pub async fn policy_registry(&self) -> Result<Vec<PolicyRegistryEntry>, CoreError> {
        self.sessions()
            .policy_registry()
            .await
            .map(|entries| entries.into_iter().map(Into::into).collect())
            .map_err(CoreError::from)
    }

    /// Adds `entry` as a default policy named `name`, with the form's parameter `values`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Rejected` for an empty name or a value of the wrong kind; the
    /// write errors.
    pub async fn add_default_policy(
        &self,
        entry: PolicyRegistryEntry,
        name: String,
        values: HashMap<String, String>,
    ) -> Result<DefaultPolicyRecord, CoreError> {
        let values: BTreeMap<String, String> = values.into_iter().collect();
        self.sessions()
            .add_default_policy(&entry.into(), &name, &values)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Mints a single-use invite link for a new account (admins on accounts servers).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `Forbidden` for a non-admin; the write errors.
    pub async fn invite_member(&self, is_admin: bool) -> Result<MemberInvite, CoreError> {
        self.sessions()
            .invite_member(is_admin)
            .await
            .map(|invite| MemberInvite {
                url: invite.url,
                expires_at: invite.expires_at,
                is_admin: invite.is_admin,
            })
            .map_err(CoreError::from)
    }
}
