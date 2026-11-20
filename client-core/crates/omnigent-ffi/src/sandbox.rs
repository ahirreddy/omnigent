//! Managed sandboxes: providers, profiles and repositories.
//!
//! Also the caller's GitHub repositories and a sandbox fork's starting repositories. The rules
//! are `omnigent_core::sandbox`'s; the REST reads are the core client's.

use omnigent_core::sandbox as core;

use crate::client::ClientCore;
use crate::configuration::ModelChoice;
use crate::creation::CreationCatalog;
use crate::errors::CoreError;

/// How a new sandbox's model catalog for a harness stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SandboxModelStatus {
    /// Models are listed.
    Ready,
    /// The provider lists none.
    Empty,
    /// The catalog could not be read; the preview's error says why.
    Unavailable,
    /// The sandbox configures no inference for the harness.
    Unconfigured,
    /// No model can serve the harness in this sandbox.
    Unsupported,
}

impl From<core::SandboxModelStatus> for SandboxModelStatus {
    fn from(status: core::SandboxModelStatus) -> Self {
        match status {
            core::SandboxModelStatus::Ready => Self::Ready,
            core::SandboxModelStatus::Empty => Self::Empty,
            core::SandboxModelStatus::Unavailable => Self::Unavailable,
            core::SandboxModelStatus::Unconfigured => Self::Unconfigured,
            core::SandboxModelStatus::Unsupported => Self::Unsupported,
        }
    }
}

/// A new sandbox's models for a harness, previewed before one is provisioned.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SandboxModelPreview {
    /// The usable rows; empty unless `status` is `Ready`.
    pub models: Vec<ModelChoice>,
    /// The sandbox configures inference for the harness, so it takes a model.
    pub configured: bool,
    /// How the catalog stands.
    pub status: SandboxModelStatus,
    /// The server's explanation for an unavailable or unsupported catalog.
    pub error: Option<String>,
}

impl From<core::SandboxModelPreview> for SandboxModelPreview {
    fn from(preview: core::SandboxModelPreview) -> Self {
        Self {
            models: preview.models.into_iter().map(Into::into).collect(),
            configured: preview.configured,
            status: preview.status.into(),
            error: preview.error,
        }
    }
}

/// A server-defined sandbox profile.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SandboxProfile {
    /// Id.
    pub id: String,
    /// Name.
    pub name: String,
    /// Description; may be empty.
    pub description: String,
    /// Its provider.
    pub provider: String,
    /// The revision a launch pins.
    pub revision: String,
}

impl From<core::SandboxProfile> for SandboxProfile {
    fn from(profile: core::SandboxProfile) -> Self {
        Self {
            id: profile.id,
            name: profile.name,
            description: profile.description,
            provider: profile.provider,
            revision: profile.revision,
        }
    }
}

impl From<SandboxProfile> for core::SandboxProfile {
    fn from(profile: SandboxProfile) -> Self {
        Self {
            id: profile.id,
            name: profile.name,
            description: profile.description,
            provider: profile.provider,
            revision: profile.revision,
        }
    }
}

/// One page of a provider's profiles.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SandboxProfilePage {
    /// The provider's profiles.
    pub profiles: Vec<SandboxProfile>,
    /// Providers whose sandboxes must launch with a profile.
    pub managed_providers: Vec<String>,
    /// More match than were returned.
    pub has_more: bool,
}

impl From<SandboxProfilePage> for core::SandboxProfilePage {
    fn from(page: SandboxProfilePage) -> Self {
        Self {
            profiles: page.profiles.into_iter().map(Into::into).collect(),
            managed_providers: page.managed_providers,
            has_more: page.has_more,
        }
    }
}

/// One repository a new sandbox clones.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SandboxRepo {
    /// Clone URL.
    pub url: String,
    /// Branch; empty for the default.
    pub branch: String,
}

impl From<SandboxRepo> for core::SandboxRepo {
    fn from(repo: SandboxRepo) -> Self {
        Self {
            url: repo.url,
            branch: repo.branch,
        }
    }
}

impl From<core::SandboxRepo> for SandboxRepo {
    fn from(repo: core::SandboxRepo) -> Self {
        Self {
            url: repo.url,
            branch: repo.branch,
        }
    }
}

/// A repository the caller's GitHub connection sees.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct GithubRepo {
    /// `owner/name`.
    pub full_name: String,
    /// Clone URL.
    pub clone_url: String,
    /// Default branch.
    pub default_branch: Option<String>,
    /// Private.
    pub is_private: bool,
}

/// The caller's GitHub repositories.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct GithubRepoList {
    /// GitHub is connected.
    pub connected: bool,
    /// Newest push first.
    pub repos: Vec<GithubRepo>,
    /// More exist than were returned.
    pub truncated: bool,
}

/// A note on one repository's branch, by URL.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SandboxRepoNote {
    /// The repository.
    pub url: String,
    /// What happened to its branch.
    pub note: String,
}

/// What a fork onto a new sandbox starts from.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ForkSandboxDefaults {
    /// The source's repositories on their pushed current branches.
    pub repos: Vec<SandboxRepo>,
    /// Branches that could not be used.
    pub notes: Vec<SandboxRepoNote>,
    /// The source's profile.
    pub profile: Option<SandboxProfile>,
    /// Why the current branches could not be read; the originals are kept.
    pub branch_check_error: Option<String>,
}

/// A sandbox row of the host menu.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SandboxProviderOption {
    /// The provider; `None` for the server's default.
    pub provider: Option<String>,
    /// `Modal Sandbox`, or `New Sandbox`.
    pub label: String,
    /// How many repositories it clones.
    pub max_repos: u32,
}

/// The sandbox rows the host menu offers, the default first; empty without managed sandboxes.
#[must_use]
#[uniffi::export]
pub fn sandbox_provider_options(catalog: CreationCatalog) -> Vec<SandboxProviderOption> {
    let catalog = omnigent_core::creation::CreationCatalog::from(catalog);
    catalog
        .capabilities
        .sandbox_provider_options()
        .into_iter()
        .map(|provider| SandboxProviderOption {
            label: core::sandbox_option_label(provider.as_deref()),
            max_repos: u32::try_from(catalog.capabilities.max_sandbox_repos(provider.as_deref()))
                .unwrap_or(1),
            provider,
        })
        .collect()
}

/// Why `url` cannot be added to `selected` (a duplicate, too long or not a repository URL).
#[must_use]
#[uniffi::export]
pub fn sandbox_url_problem(url: String, selected: Vec<SandboxRepo>) -> Option<String> {
    let selected: Vec<core::SandboxRepo> = selected.into_iter().map(Into::into).collect();
    core::sandbox_url_problem(&url, &selected)
}

/// The input a sandbox repository problem shows under.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SandboxRepoField {
    /// The repository URL.
    Repository,
    /// The branch.
    Branch,
}

/// Why a sandbox's repository and branch can't be sent, and the input it belongs under.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SandboxRepoProblem {
    /// The input.
    pub field: SandboxRepoField,
    /// What to show.
    pub message: String,
}

/// Why Switch Host's sandbox repository and branch can't be sent (the web's
/// `sandboxRepoProblem`); `None` when they can. A blank repository is an empty sandbox.
#[must_use]
#[uniffi::export]
pub fn sandbox_move_problem(repository: String, branch: String) -> Option<SandboxRepoProblem> {
    core::sandbox_move_problem(&repository, &branch).map(|problem| SandboxRepoProblem {
        field: match problem.field {
            core::SandboxRepoField::Repository => SandboxRepoField::Repository,
            core::SandboxRepoField::Branch => SandboxRepoField::Branch,
        },
        message: problem.message,
    })
}

/// Why `branch` of `url` cannot be used.
#[must_use]
#[uniffi::export]
pub fn sandbox_branch_problem(url: String, branch: String) -> Option<String> {
    core::sandbox_branch_problem(&url, &branch)
}

/// Why `repos` cannot start a sandbox that clones at most `max`.
#[must_use]
#[uniffi::export]
pub fn sandbox_repos_problem(repos: Vec<SandboxRepo>, max: u32) -> Option<String> {
    let repos: Vec<core::SandboxRepo> = repos.into_iter().map(Into::into).collect();
    core::sandbox_repos_problem(&repos, usize::try_from(max).unwrap_or(usize::MAX))
}

/// `repos` as `<url>[#<branch>]` workspaces.
#[must_use]
#[uniffi::export]
pub fn compose_sandbox_workspaces(repos: Vec<SandboxRepo>) -> Vec<String> {
    let repos: Vec<core::SandboxRepo> = repos.into_iter().map(Into::into).collect();
    core::compose_sandbox_workspaces(&repos)
}

/// A repository's display name (its clone directory).
#[must_use]
#[uniffi::export]
pub fn sandbox_repo_name(url: String) -> String {
    core::derive_repo_name(&url).unwrap_or(url)
}

/// Whether two repository URLs name the same repository.
#[must_use]
#[uniffi::export]
pub fn is_same_sandbox_repo(first: String, second: String) -> bool {
    core::repo_identity(&first) == core::repo_identity(&second)
}

/// Why a sandbox of `provider` cannot launch with `selected`, given its profile `page`.
#[must_use]
#[uniffi::export]
pub fn sandbox_profile_problem(
    page: SandboxProfilePage,
    provider: String,
    selected: Option<SandboxProfile>,
) -> Option<String> {
    let selected = selected.map(core::SandboxProfile::from);
    core::sandbox_profile_problem(&page.into(), &provider, selected.as_ref())
}

#[uniffi::export]
impl ClientCore {
    /// `provider`'s profiles matching `search` (all when blank), or only `profile_id`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn sandbox_profiles(
        &self,
        provider: String,
        search: String,
        profile_id: Option<String>,
    ) -> Result<SandboxProfilePage, CoreError> {
        let page = self
            .sessions()
            .sandbox_profiles(&provider, &search, profile_id.as_deref())
            .await
            .map_err(CoreError::from)?;
        Ok(SandboxProfilePage {
            profiles: page.profiles.into_iter().map(Into::into).collect(),
            managed_providers: page.managed_providers,
            has_more: page.has_more,
        })
    }

    /// What a new sandbox of `provider` offers `harness` for `agent_id`, before one is
    /// provisioned.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors and `MalformedResponse`.
    pub async fn sandbox_model_preview(
        &self,
        provider: String,
        harness: String,
        agent_id: String,
    ) -> Result<SandboxModelPreview, CoreError> {
        self.sessions()
            .sandbox_model_preview(&provider, &harness, &agent_id)
            .await
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// The caller's GitHub repositories, newest push first.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the read errors and `MalformedResponse`.
    pub async fn github_repos(&self) -> Result<GithubRepoList, CoreError> {
        let list = self
            .sessions()
            .github_repos()
            .await
            .map_err(CoreError::from)?;
        Ok(GithubRepoList {
            connected: list.connected,
            truncated: list.truncated,
            repos: list
                .repos
                .into_iter()
                .map(|repo| GithubRepo {
                    full_name: repo.full_name,
                    clone_url: repo.clone_url,
                    default_branch: repo.default_branch,
                    is_private: repo.private,
                })
                .collect(),
        })
    }

    /// The branches of the GitHub repository `full_name` (`owner/name`).
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: `InvalidIdentifier`, the read errors and `MalformedResponse`.
    pub async fn github_branches(&self, full_name: String) -> Result<Vec<String>, CoreError> {
        self.sessions()
            .github_branches(&full_name)
            .await
            .map_err(CoreError::from)
    }

    /// The repositories and profile a fork of `source_id` onto a new sandbox starts from.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]: the source's read errors and `MalformedResponse`.
    pub async fn fork_sandbox_defaults(
        &self,
        source_id: String,
    ) -> Result<ForkSandboxDefaults, CoreError> {
        let defaults = self
            .sessions()
            .fork_sandbox_defaults(&source_id)
            .await
            .map_err(CoreError::from)?;
        Ok(ForkSandboxDefaults {
            repos: defaults.repos.repos.into_iter().map(Into::into).collect(),
            notes: defaults
                .repos
                .notes
                .into_iter()
                .map(|(url, note)| SandboxRepoNote { url, note })
                .collect(),
            profile: defaults.profile.map(Into::into),
            branch_check_error: defaults.branch_check_error,
        })
    }
}
