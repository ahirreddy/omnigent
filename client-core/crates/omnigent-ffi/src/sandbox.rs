//! Managed sandboxes: providers, profiles and repositories.
//!
//! Also the caller's GitHub repositories and a sandbox fork's starting repositories. The rules
//! are `omnigent_core::sandbox`'s; the REST reads are the core client's.

use omnigent_core::sandbox as core;

use crate::client::ClientCore;
use crate::creation::CreationCatalog;
use crate::errors::CoreError;

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
