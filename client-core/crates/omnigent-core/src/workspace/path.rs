//! Workspace-relative paths that can never leave the environment root.
//!
//! Every path the workspace API sends is a [`WorkspacePath`]. Parsing normalizes the input the
//! way the runner does (`os.path.normpath` in `environment_filesystem._validate_path`) and then
//! rejects what the server would refuse, before any request:
//!
//! - an absolute path (a leading `/`). Browsing outside the workspace (`base=host`) is owner-only
//!   and not part of this client;
//! - any `..` segment, wherever it appears. The server's route layer rejects these even when they
//!   would resolve inside the root (`_runner_path_segment`), so `a/../b` is refused too;
//! - NUL and other control characters, which no workspace file name the server serves contains;
//! - paths longer than [`MAX_PATH_BYTES`].
//!
//! `.` segments, empty segments (`a//b`) and a trailing slash are dropped. The empty path is the
//! environment root.

use std::fmt;

/// The longest path accepted, in UTF-8 bytes.
pub const MAX_PATH_BYTES: usize = 4096;

/// Why a path cannot be sent.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PathError {
    /// The path starts with `/`.
    #[error("Use a path inside the workspace, not an absolute path.")]
    Absolute,
    /// The path has a `..` segment.
    #[error("Paths cannot contain `..`.")]
    Traversal,
    /// The path contains NUL or another control character.
    #[error("The path contains a control character.")]
    ControlCharacter,
    /// The path is longer than [`MAX_PATH_BYTES`].
    #[error("The path is too long.")]
    TooLong,
    /// The root was given where a file or directory below it is required.
    #[error("Choose a file inside the workspace.")]
    Root,
}

/// A normalized path relative to an environment root. The empty path is the root.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct WorkspacePath(String);

impl WorkspacePath {
    /// The environment root.
    #[must_use]
    pub const fn root() -> Self {
        Self(String::new())
    }

    /// Parses and normalizes `raw`.
    ///
    /// # Errors
    ///
    /// See [`PathError`].
    pub fn parse(raw: &str) -> Result<Self, PathError> {
        if raw.len() > MAX_PATH_BYTES {
            return Err(PathError::TooLong);
        }
        if raw.chars().any(char::is_control) {
            return Err(PathError::ControlCharacter);
        }
        if raw.starts_with('/') {
            return Err(PathError::Absolute);
        }
        let mut segments = Vec::new();
        for segment in raw.split('/') {
            match segment {
                "" | "." => {}
                ".." => return Err(PathError::Traversal),
                other => segments.push(other),
            }
        }
        Ok(Self(segments.join("/")))
    }

    /// Parses `raw` and requires a path below the root.
    ///
    /// # Errors
    ///
    /// See [`WorkspacePath::parse`]; [`PathError::Root`] for the root itself.
    pub fn parse_file(raw: &str) -> Result<Self, PathError> {
        let path = Self::parse(raw)?;
        if path.is_root() {
            return Err(PathError::Root);
        }
        Ok(path)
    }

    /// The normalized text: segments joined by `/`, no leading or trailing slash.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Whether this is the environment root.
    #[must_use]
    pub const fn is_root(&self) -> bool {
        self.0.is_empty()
    }

    /// The segments, outermost first. The root has none.
    pub fn segments(&self) -> impl Iterator<Item = &str> {
        self.0.split('/').filter(|segment| !segment.is_empty())
    }

    /// The number of segments.
    #[must_use]
    pub fn depth(&self) -> usize {
        self.segments().count()
    }

    /// The last segment; empty for the root.
    #[must_use]
    pub fn name(&self) -> &str {
        self.0.rsplit('/').next().unwrap_or_default()
    }

    /// The extension of [`WorkspacePath::name`], without the dot. A leading dot (`.gitignore`)
    /// is part of the name, not an extension.
    #[must_use]
    pub fn extension(&self) -> Option<&str> {
        let name = self.name();
        let (stem, extension) = name.rsplit_once('.')?;
        (!stem.is_empty() && !extension.is_empty()).then_some(extension)
    }

    /// The containing directory; `None` for the root.
    #[must_use]
    pub fn parent(&self) -> Option<Self> {
        if self.is_root() {
            return None;
        }
        Some(
            self.0
                .rsplit_once('/')
                .map_or_else(Self::root, |(parent, _)| Self(parent.to_owned())),
        )
    }

    /// Every ancestor from the root down to the parent, outermost first.
    #[must_use]
    pub fn ancestors(&self) -> Vec<Self> {
        let mut ancestors = Vec::new();
        let mut current = self.parent();
        while let Some(path) = current {
            current = path.parent();
            ancestors.push(path);
        }
        ancestors.reverse();
        ancestors
    }

    /// `relative` resolved under this path.
    ///
    /// # Errors
    ///
    /// See [`WorkspacePath::parse`]; the joined path is checked as a whole.
    pub fn join(&self, relative: &str) -> Result<Self, PathError> {
        if relative.starts_with('/') {
            return Err(PathError::Absolute);
        }
        if self.is_root() {
            return Self::parse(relative);
        }
        Self::parse(&format!("{}/{relative}", self.0))
    }

    /// Whether `ancestor` is this path or contains it. Every path is under the root.
    #[must_use]
    pub fn is_within(&self, ancestor: &Self) -> bool {
        ancestor.is_root()
            || self.0 == ancestor.0
            || self
                .0
                .strip_prefix(ancestor.as_str())
                .is_some_and(|rest| rest.starts_with('/'))
    }

    /// This path relative to `ancestor`, when it is within it.
    #[must_use]
    pub fn strip_ancestor(&self, ancestor: &Self) -> Option<&str> {
        if ancestor.is_root() {
            return Some(self.as_str());
        }
        if self.0 == ancestor.0 {
            return Some("");
        }
        self.0
            .strip_prefix(ancestor.as_str())
            .and_then(|rest| rest.strip_prefix('/'))
    }
}

impl fmt::Display for WorkspacePath {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// The absolute location of `path` on the environment's own filesystem.
///
/// For "Reveal in Finder" or "Copy absolute path". `root` is the environment root the server reports (for example
/// `metadata.root`); it is only meaningful on the machine that runs the environment.
#[must_use]
pub fn absolute_location(root: &str, path: &WorkspacePath) -> String {
    let root = root.trim_end_matches('/');
    if path.is_root() {
        return if root.is_empty() {
            "/".to_owned()
        } else {
            root.to_owned()
        };
    }
    format!("{root}/{path}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(raw: &str) -> String {
        WorkspacePath::parse(raw).unwrap().as_str().to_owned()
    }

    #[test]
    fn stripping_the_root_or_the_path_itself_and_locating_the_root_are_exact() {
        let path = WorkspacePath::parse("a/b").unwrap();
        assert_eq!(path.strip_ancestor(&WorkspacePath::root()), Some("a/b"));
        assert_eq!(path.strip_ancestor(&path), Some(""));
        assert_eq!(absolute_location("/", &WorkspacePath::root()), "/");
        assert_eq!(absolute_location("/srv/", &WorkspacePath::root()), "/srv");
    }

    #[test]
    fn normalizes_like_the_runner() {
        assert_eq!(parsed(""), "");
        assert_eq!(parsed("."), "");
        assert_eq!(parsed("./"), "");
        assert_eq!(parsed("src"), "src");
        assert_eq!(parsed("src/"), "src");
        assert_eq!(parsed("./src//main.rs"), "src/main.rs");
        assert_eq!(parsed("src/./util/mod.rs"), "src/util/mod.rs");
        assert_eq!(parsed("docs/café notes.md"), "docs/café notes.md");
        assert_eq!(
            parsed("a\\b"),
            "a\\b",
            "a backslash is a name character on the server"
        );
        assert_eq!(parsed(".gitignore"), ".gitignore");
        assert_eq!(
            parsed("...."),
            "....",
            "only exactly `..` is a parent segment"
        );
    }

    #[test]
    fn rejects_everything_that_could_leave_the_root() {
        for raw in [
            "..",
            "../etc/passwd",
            "src/../../etc/passwd",
            "src/..",
            "a/../b",
            "./..",
        ] {
            assert_eq!(
                WorkspacePath::parse(raw),
                Err(PathError::Traversal),
                "{raw}"
            );
        }
        for raw in ["/", "/etc/passwd", "//server/share"] {
            assert_eq!(WorkspacePath::parse(raw), Err(PathError::Absolute), "{raw}");
        }
        for raw in ["a\0b", "a\nb", "a\rb", "a\tb", "\u{7f}"] {
            assert_eq!(
                WorkspacePath::parse(raw),
                Err(PathError::ControlCharacter),
                "{raw:?}"
            );
        }
        assert_eq!(
            WorkspacePath::parse(&"a".repeat(MAX_PATH_BYTES + 1)),
            Err(PathError::TooLong)
        );
        assert_eq!(WorkspacePath::parse_file("./"), Err(PathError::Root));
    }

    #[test]
    fn navigation_helpers() {
        let path = WorkspacePath::parse("src/util/mod.rs").unwrap();
        assert_eq!(path.name(), "mod.rs");
        assert_eq!(path.extension(), Some("rs"));
        assert_eq!(path.depth(), 3);
        assert_eq!(path.parent().unwrap().as_str(), "src/util");
        assert_eq!(
            path.ancestors()
                .iter()
                .map(WorkspacePath::as_str)
                .collect::<Vec<_>>(),
            ["", "src", "src/util"]
        );
        assert_eq!(WorkspacePath::root().parent(), None);
        assert_eq!(WorkspacePath::root().name(), "");
        assert_eq!(
            WorkspacePath::parse(".gitignore").unwrap().extension(),
            None
        );
        assert_eq!(WorkspacePath::parse("Makefile").unwrap().extension(), None);
        assert_eq!(
            WorkspacePath::parse("a.tar.gz").unwrap().extension(),
            Some("gz")
        );

        let src = WorkspacePath::parse("src").unwrap();
        assert_eq!(src.join("lib.rs").unwrap().as_str(), "src/lib.rs");
        assert_eq!(src.join("../x"), Err(PathError::Traversal));
        assert_eq!(src.join("/etc"), Err(PathError::Absolute));
        assert!(path.is_within(&src));
        assert!(src.is_within(&src));
        assert!(path.is_within(&WorkspacePath::root()));
        let sibling = WorkspacePath::parse("srcx/a").unwrap();
        assert!(!sibling.is_within(&src));
        assert_eq!(path.strip_ancestor(&src), Some("util/mod.rs"));
        assert_eq!(sibling.strip_ancestor(&src), None);
    }

    #[test]
    fn absolute_locations_join_the_reported_root() {
        let path = WorkspacePath::parse("src/main.rs").unwrap();
        assert_eq!(
            absolute_location("/workspace/fixture/", &path),
            "/workspace/fixture/src/main.rs"
        );
        assert_eq!(
            absolute_location("/workspace/fixture", &WorkspacePath::root()),
            "/workspace/fixture"
        );
        assert_eq!(absolute_location("/", &path), "/src/main.rs");
    }
}
