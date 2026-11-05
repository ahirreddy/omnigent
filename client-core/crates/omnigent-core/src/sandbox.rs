//! Managed sandboxes: the providers and profiles a new sandbox can use, the repositories it
//! clones, and the GitHub listings the repository picker offers.
//!
//! Port of the web's `lib/sandboxRepositories.ts`, `components/SandboxProfilePicker.tsx`,
//! `shell/SandboxRepositoryPicker.tsx` and the fork dialog's branch discovery. The REST reads
//! (`GET /v1/sandbox-profiles`, `GET /v1/connections/github/repos[/{repo}/branches]` and
//! `GET /v1/sessions/{id}/resources/repository-branches`) are [`crate::ClientCore`] methods in
//! `client::sandbox`.

use serde_json::Value;

use crate::client::json::{as_object, opt_array, opt_bool, opt_str, req_str};

/// The most repositories one sandbox clones (the server's `_MAX_MANAGED_WORKSPACES`).
pub const MAX_SANDBOX_REPOS: usize = 10;

/// The longest `<url>[#<branch>]`, in characters (the server's label value limit).
pub const MAX_SANDBOX_WORKSPACE_CHARS: usize = 256;

/// The most profiles one listing asks for.
pub const SANDBOX_PROFILE_LIMIT: usize = 20;

/// The session label holding the space-joined `<url>[#<branch>]` repositories it cloned.
pub const SANDBOX_REPO_LABEL: &str = "omnigent.sandbox.repo";

/// Shown for a branch the server would refuse.
pub const INVALID_BRANCH_MESSAGE: &str =
    "Enter a valid branch name, or leave blank for the default branch.";

/// Shown for a repository and branch too long for the server's label.
pub const WORKSPACE_LENGTH_MESSAGE: &str =
    "Repository URL and branch must be at most 256 characters together.";

/// One repository a new sandbox clones.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct SandboxRepo {
    /// `https://<host>/<path>` or `git@<host>:<path>`.
    pub url: String,
    /// The branch; empty for the repository's default.
    pub branch: String,
}

/// Whether `url` is a repository URL the server clones: `https://<host>/<path>` or
/// `git@<host>:<path>`, without `user@` credentials, ending in a usable directory name.
#[must_use]
pub fn is_valid_sandbox_repo_url(url: &str) -> bool {
    let url = url.trim();
    let forbidden = |c: char| c.is_whitespace() || c == '#' || c == '@';
    let https = url.strip_prefix("https://").is_some_and(|rest| {
        let Some((host, path)) = rest.split_once('/') else {
            return false;
        };
        let path = path.trim_start_matches('/');
        !host.is_empty()
            && !host.chars().any(forbidden)
            && !path.is_empty()
            && !path.chars().any(forbidden)
    });
    let ssh = url.strip_prefix("git@").is_some_and(|rest| {
        let Some((host, path)) = rest.split_once(':') else {
            return false;
        };
        !host.is_empty()
            && !host.chars().any(|c| forbidden(c) || c == ':')
            && !path.is_empty()
            && !path.chars().any(forbidden)
    });
    (https || ssh)
        && derive_repo_name(url).is_some_and(|name| {
            name != "."
                && name != ".."
                && name
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        })
}

/// Whether `branch` is one the server accepts; blank selects the repository default.
#[must_use]
pub fn is_valid_sandbox_branch(branch: &str) -> bool {
    let value = branch.trim();
    if value.is_empty() {
        return true;
    }
    let is_sha = value.len() == 40 && value.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f'));
    !is_sha
        && !value
            .chars()
            .any(|c| u32::from(c) < 0x20 || c.is_whitespace() || "~^:?*[\\#".contains(c))
        && !value.starts_with(['-', '/'])
        && !value.ends_with(['/', '.'])
        && !value.contains("..")
        && !value.contains("@{")
}

/// `<url>[#<branch>]`, or `None` for a blank URL.
#[must_use]
pub fn compose_sandbox_workspace(url: &str, branch: &str) -> Option<String> {
    let url = url.trim();
    if url.is_empty() {
        return None;
    }
    let branch = branch.trim();
    Some(if branch.is_empty() {
        url.to_owned()
    } else {
        format!("{url}#{branch}")
    })
}

/// Splits `<url>[#<branch>]` on its first `#`.
#[must_use]
pub fn split_sandbox_workspace(workspace: &str) -> SandboxRepo {
    match workspace.split_once('#') {
        Some((url, branch)) => SandboxRepo {
            url: url.to_owned(),
            branch: branch.to_owned(),
        },
        None => SandboxRepo {
            url: workspace.to_owned(),
            branch: String::new(),
        },
    }
}

/// The `workspaces` of a sandbox create: each repository as `<url>[#<branch>]`, blanks dropped.
#[must_use]
pub fn compose_sandbox_workspaces(repos: &[SandboxRepo]) -> Vec<String> {
    repos
        .iter()
        .filter_map(|repo| compose_sandbox_workspace(&repo.url, &repo.branch))
        .collect()
}

/// Whether `url` and `branch` fit the server's limit together.
#[must_use]
pub fn fits_sandbox_workspace(url: &str, branch: &str) -> bool {
    compose_sandbox_workspace(url, branch)
        .unwrap_or_default()
        .chars()
        .count()
        <= MAX_SANDBOX_WORKSPACE_CHARS
}

/// The clone directory's name: the URL's last path segment without `.git`.
#[must_use]
pub fn derive_repo_name(url: &str) -> Option<String> {
    let trimmed = url.trim().trim_end_matches('/');
    let last = trimmed.rsplit(['/', ':']).next().unwrap_or_default();
    let name = last.strip_suffix(".git").unwrap_or(last);
    (!name.is_empty()).then(|| name.to_owned())
}

/// A repository's identity for duplicate checks: SSH as HTTPS, GitHub case-insensitive, no
/// trailing `/` or `.git`.
#[must_use]
pub fn repo_identity(url: &str) -> String {
    let mut normalized = url.trim().to_owned();
    if let Some(rest) = normalized.strip_prefix("git@")
        && let Some((host, path)) = rest.split_once(':')
    {
        normalized = format!("https://{host}/{path}");
    }
    let mut normalized = normalized.trim_end_matches('/').to_owned();
    if normalized
        .to_ascii_lowercase()
        .starts_with("https://github.com/")
    {
        normalized = normalized.to_ascii_lowercase();
    }
    let stripped = normalized.strip_suffix(".git").map(str::to_owned);
    stripped.unwrap_or(normalized)
}

/// Why `url` cannot be added to `selected`, or `None` when it can (blank is not addable but
/// not a problem either).
#[must_use]
pub fn sandbox_url_problem(url: &str, selected: &[SandboxRepo]) -> Option<String> {
    if url.trim().is_empty() {
        return None;
    }
    let identity = repo_identity(url);
    if selected
        .iter()
        .any(|repo| repo_identity(&repo.url) == identity)
    {
        return Some("This repository is already selected. Clear this URL to continue.".into());
    }
    if !fits_sandbox_workspace(url, "") {
        return Some(WORKSPACE_LENGTH_MESSAGE.into());
    }
    if !is_valid_sandbox_repo_url(url) {
        return Some("Enter an HTTPS or SSH URL ending in a repository name.".into());
    }
    None
}

/// Why `branch` of `url` cannot be used, or `None` when it can.
#[must_use]
pub fn sandbox_branch_problem(url: &str, branch: &str) -> Option<String> {
    if !is_valid_sandbox_branch(branch) {
        Some(INVALID_BRANCH_MESSAGE.into())
    } else if !fits_sandbox_workspace(url, branch) {
        Some(WORKSPACE_LENGTH_MESSAGE.into())
    } else {
        None
    }
}

/// Why `repos` cannot start a sandbox that clones at most `max`, or `None` when they can.
#[must_use]
pub fn sandbox_repos_problem(repos: &[SandboxRepo], max: usize) -> Option<String> {
    if repos.len() > max {
        let noun = if max == 1 {
            "repository"
        } else {
            "repositories"
        };
        return Some(format!(
            "This sandbox provider clones at most {max} {noun}. Remove the extra repositories to continue."
        ));
    }
    repos.iter().find_map(|repo| {
        if is_valid_sandbox_repo_url(&repo.url) {
            sandbox_branch_problem(&repo.url, &repo.branch)
        } else {
            Some(format!("{} is not a repository URL.", repo.url.trim()))
        }
    })
}

/// The new-session label for a sandbox of `provider`: `Modal Sandbox`, or `New Sandbox` when
/// the server names none.
#[must_use]
pub fn sandbox_option_label(provider: Option<&str>) -> String {
    let Some(provider) = provider.filter(|provider| !provider.is_empty()) else {
        return "New Sandbox".to_owned();
    };
    let name = match provider {
        "modal" => "Modal".to_owned(),
        "lakebox" => "Databricks".to_owned(),
        "daytona" => "Daytona".to_owned(),
        "e2b" => "E2B".to_owned(),
        other => {
            let mut chars = other.chars();
            chars.next().map_or_else(String::new, |first| {
                first.to_uppercase().chain(chars).collect()
            })
        }
    };
    format!("{name} Sandbox")
}

/// A server-defined sandbox profile (`GET /v1/sandbox-profiles`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct SandboxProfile {
    /// Id.
    pub id: String,
    /// Name.
    pub name: String,
    /// Description; may be empty.
    pub description: String,
    /// The provider it belongs to.
    pub provider: String,
    /// The revision a launch pins.
    pub revision: String,
}

/// One page of sandbox profiles.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SandboxProfilePage {
    /// The profiles of the asked provider.
    pub profiles: Vec<SandboxProfile>,
    /// Providers whose sandboxes must launch with a profile.
    pub managed_providers: Vec<String>,
    /// More profiles match than were returned.
    pub has_more: bool,
}

impl SandboxProfilePage {
    /// Decodes a listing, keeping only `provider`'s profiles.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value, provider: &str) -> Result<Self, String> {
        let object = as_object(value, "sandbox profiles")?;
        let mut profiles = Vec::new();
        for row in opt_array(object, "profiles")?.into_iter().flatten() {
            let row = as_object(row, "sandbox profile")?;
            let profile = SandboxProfile {
                id: req_str(row, "id")?,
                name: req_str(row, "name")?,
                description: opt_str(row, "description")?.unwrap_or_default(),
                provider: req_str(row, "provider")?,
                revision: req_str(row, "revision")?,
            };
            if profile.provider == provider {
                profiles.push(profile);
            }
        }
        Ok(Self {
            profiles,
            managed_providers: strings(
                opt_array(object, "managed_providers")?,
                "managed_providers",
            )?,
            has_more: opt_str(object, "next_cursor")?.is_some(),
        })
    }

    /// Whether a sandbox of `provider` must launch with a profile.
    #[must_use]
    pub fn requires_profile(&self, provider: &str) -> bool {
        self.managed_providers.iter().any(|name| name == provider)
    }
}

/// Why a sandbox of `provider` cannot launch with `selected` given its profile `page`, or
/// `None` when it can (or needs no profile).
#[must_use]
pub fn sandbox_profile_problem(
    page: &SandboxProfilePage,
    provider: &str,
    selected: Option<&SandboxProfile>,
) -> Option<String> {
    if !page.requires_profile(provider) {
        return None;
    }
    match selected {
        Some(profile) if profile.provider == provider => None,
        _ if page.profiles.is_empty() => {
            Some("No sandbox profiles available for this provider.".into())
        }
        _ => Some("Choose a sandbox profile to continue.".into()),
    }
}

/// A repository the caller's GitHub connection can see.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct GithubRepo {
    /// `owner/name`.
    pub full_name: String,
    /// The URL a sandbox clones.
    pub clone_url: String,
    /// Default branch, when known.
    pub default_branch: Option<String>,
    /// Private.
    pub private: bool,
}

/// `GET /v1/connections/github/repos`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GithubRepoList {
    /// GitHub is connected; otherwise `repos` is empty.
    pub connected: bool,
    /// Newest push first.
    pub repos: Vec<GithubRepo>,
    /// More exist than were returned.
    pub truncated: bool,
}

impl GithubRepoList {
    /// Decodes a listing.
    ///
    /// # Errors
    ///
    /// A description of the first field with the wrong shape.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let object = as_object(value, "github repos")?;
        let mut repos = Vec::new();
        for row in opt_array(object, "repos")?.into_iter().flatten() {
            let row = as_object(row, "github repo")?;
            let full_name = req_str(row, "full_name")?;
            repos.push(GithubRepo {
                clone_url: opt_str(row, "clone_url")?
                    .unwrap_or_else(|| format!("https://github.com/{full_name}.git")),
                full_name,
                default_branch: opt_str(row, "default_branch")?,
                private: opt_bool(row, "private")?.unwrap_or(false),
            });
        }
        let connected = opt_bool(object, "connected")?.unwrap_or(false);
        Ok(Self {
            repos: if connected { repos } else { Vec::new() },
            connected,
            truncated: opt_bool(object, "truncated")?.unwrap_or(false),
        })
    }
}

/// Decodes `GET .../github/repos/{owner}/{repo}/branches`: the names, empty when GitHub is not
/// connected.
///
/// # Errors
///
/// A description of the first field with the wrong shape.
pub fn github_branches(value: &Value) -> Result<Vec<String>, String> {
    let object = as_object(value, "github branches")?;
    if opt_bool(object, "connected")? != Some(true) {
        return Ok(Vec::new());
    }
    strings(opt_array(object, "branches")?, "branches")
}

/// One managed repository's current branch in a session's sandbox.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RepositoryBranch {
    /// Clone URL, as launched.
    pub url: String,
    /// The checked-out branch; `None` when detached or unknown.
    pub branch: Option<String>,
    /// The branch exists at the clone URL; `None` when unknown.
    pub pushed: Option<bool>,
}

/// Decodes `GET /v1/sessions/{id}/resources/repository-branches`.
///
/// # Errors
///
/// A description of the first field with the wrong shape.
pub fn repository_branches(value: &Value) -> Result<Vec<RepositoryBranch>, String> {
    let object = as_object(value, "repository branches")?;
    opt_array(object, "repositories")?
        .into_iter()
        .flatten()
        .map(|row| {
            let row = as_object(row, "repository branch")?;
            Ok(RepositoryBranch {
                url: req_str(row, "url")?,
                branch: opt_str(row, "branch")?.filter(|branch| !branch.is_empty()),
                pushed: opt_bool(row, "pushed")?,
            })
        })
        .collect()
}

/// A fork's sandbox repositories, from the source's and their current branches.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ForkSandboxRepos {
    /// The repositories, each on its pushed current branch when there is one.
    pub repos: Vec<SandboxRepo>,
    /// Notes by URL for branches that could not be used.
    pub notes: Vec<(String, String)>,
}

/// What a fork onto a new sandbox starts from: the source's repositories (on their current
/// pushed branches) and profile.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ForkSandboxDefaults {
    /// The repositories and notes for branches that could not be used.
    pub repos: ForkSandboxRepos,
    /// The source's sandbox profile, when it launched with one.
    pub profile: Option<SandboxProfile>,
    /// Why the current branches could not be read; the original branches are kept.
    pub branch_check_error: Option<String>,
}

/// The source's repositories, each moved to its current branch when that branch is pushed and
/// usable (the web's fork branch discovery). A URL listed twice is left as it was.
#[must_use]
pub fn fork_sandbox_repos(original: &[SandboxRepo], live: &[RepositoryBranch]) -> ForkSandboxRepos {
    let repeated = |urls: Vec<&str>| {
        let mut seen = std::collections::BTreeSet::new();
        urls.into_iter()
            .filter(|url| !seen.insert(*url))
            .map(str::to_owned)
            .collect::<std::collections::BTreeSet<_>>()
    };
    let mut ambiguous = repeated(original.iter().map(|repo| repo.url.as_str()).collect());
    ambiguous.extend(repeated(
        live.iter().map(|repo| repo.url.as_str()).collect(),
    ));
    let current = |url: &str| {
        (!ambiguous.contains(url))
            .then(|| live.iter().find(|repo| repo.url == url))
            .flatten()
    };
    let mut result = ForkSandboxRepos::default();
    for repo in original {
        let mut chosen = repo.clone();
        if let Some(live) = current(&repo.url)
            && let Some(branch) = &live.branch
        {
            match live.pushed {
                Some(true) if sandbox_branch_problem(&repo.url, branch).is_none() => {
                    chosen.branch.clone_from(branch);
                }
                Some(false) => {
                    let fallback = if repo.branch.is_empty() {
                        "the default branch".to_owned()
                    } else {
                        repo.branch.clone()
                    };
                    result.notes.push((
                        repo.url.clone(),
                        format!("\u{201c}{branch}\u{201d} isn\u{2019}t pushed. Using {fallback}."),
                    ));
                }
                _ => {}
            }
        }
        result.repos.push(chosen);
    }
    result
}

fn strings(values: Option<&Vec<Value>>, key: &str) -> Result<Vec<String>, String> {
    values
        .into_iter()
        .flatten()
        .map(|value| {
            value
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| format!("`{key}` holds a non-string"))
        })
        .collect()
}

#[cfg(test)]
#[path = "sandbox_tests.rs"]
mod tests;
