//! The sidebar's projects and the pages of its open folders, read by the engine as soon as the
//! connection is up rather than after the app draws its first frame: the projects and their sort
//! order at once, beside the list's first page, then the first page of each folder the sidebar
//! shows open (the web's `?project=` read). A list reload reads the open folders again; their
//! rows stay shown meanwhile, and folders that are closed by then are forgotten.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use omnigent_core::SessionError;
use omnigent_core::project_settings::ProjectSortMode as CoreSortMode;
use omnigent_core::projects::ProjectSummary as CoreProject;
use omnigent_core::sessions::{SessionPage, SessionSummary};

use crate::engine::{Engine, Msg};
use crate::errors::CoreError;
use crate::events::CoreEvent;
use crate::list_driver::ListMsg;
use crate::runtime::post;
use crate::sessions::{PROJECT_PAGE_LIMIT, ProjectSummary};
use crate::sidebar::ProjectSortMode;

/// The id of `project`'s sidebar folder: its first-class id, else its name for a label-only
/// project.
#[must_use]
#[uniffi::export]
pub fn project_folder_id(project: ProjectSummary) -> String {
    folder_id(&project.into())
}

fn folder_id(project: &CoreProject) -> String {
    project
        .id
        .clone()
        .unwrap_or_else(|| format!("label:{}", project.name))
}

/// One folder's pages, as the app is told them.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ProjectFolderPaging {
    /// The folder ([`project_folder_id`]).
    pub folder_id: String,
    /// Its first page was read.
    pub is_loaded: bool,
    /// Members exist after the loaded pages.
    pub has_more_after: bool,
    /// A page the app asked for is loading.
    pub is_loading: bool,
}

/// What the engine knows of the projects and their folders.
#[derive(Default)]
pub(crate) struct Folders {
    /// The projects read on this connection; `None` before the first read lands.
    projects: Option<Vec<CoreProject>>,
    /// Bumped by each projects read; older answers are dropped.
    projects_read: u64,
    /// The folders the sidebar shows open; kept across connections, as the sidebar keeps them.
    open: BTreeSet<String>,
    pages: BTreeMap<String, FolderPages>,
    /// Bumped by every read; a folder's answer counts only when it is its latest read.
    next_read: u64,
    /// What the app was last told.
    reported: Vec<ProjectFolderPaging>,
}

#[derive(Default)]
struct FolderPages {
    project: Option<CoreProject>,
    loaded: bool,
    next_cursor: Option<String>,
    /// The read in flight, if any, and whether the app waits on it (a reload's does not show).
    reading: Option<(u64, bool)>,
    /// Every loaded page's rows; a reload's page keeps showing them.
    rows: Vec<SessionSummary>,
}

impl Folders {
    /// A new connection: the open folders stay, nothing read on the old one does.
    pub(crate) fn for_new_connection(&mut self) -> Self {
        Self {
            open: std::mem::take(&mut self.open),
            projects_read: self.projects_read.wrapping_add(1),
            next_read: self.next_read,
            reported: std::mem::take(&mut self.reported),
            ..Self::default()
        }
    }

    /// The loaded folders' rows, which a list reload keeps showing.
    pub(crate) fn rows(&self) -> impl Iterator<Item = &SessionSummary> {
        self.pages.values().flat_map(|pages| pages.rows.iter())
    }

    fn project(&self, folder: &str) -> Option<CoreProject> {
        self.projects
            .as_ref()?
            .iter()
            .find(|project| folder_id(project) == folder)
            .cloned()
    }

    fn paging(&self) -> Vec<ProjectFolderPaging> {
        self.pages
            .iter()
            .map(|(folder, pages)| ProjectFolderPaging {
                folder_id: folder.clone(),
                is_loaded: pages.loaded,
                has_more_after: pages.next_cursor.is_some(),
                is_loading: pages.reading.is_some_and(|(_, shown)| shown),
            })
            .collect()
    }
}

/// What a folder read is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FolderRead {
    /// The first page, which the app waits on.
    First,
    /// The page after the loaded ones.
    Next,
    /// The first page again, for a list reload: its rows replace the folder's without a wait.
    Again,
}

impl Engine {
    /// Reads the projects and their sort order at once.
    pub(crate) fn read_projects(&mut self) {
        if !self.is_connected() {
            return;
        }
        let folders = &mut self.list.folders;
        folders.projects_read = folders.projects_read.wrapping_add(1);
        let read = folders.projects_read;
        let sessions = Arc::clone(&self.sessions);
        let tx = self.sender();
        self.host.spawn(async move {
            let (projects, mode) =
                futures::future::join(sessions.projects(), sessions.project_sort_mode()).await;
            let result = projects.and_then(|projects| mode.map(|mode| (projects, mode)));
            post(&tx, Msg::List(ListMsg::ProjectsLoaded { read, result }));
        });
    }

    pub(crate) fn projects_loaded(
        &mut self,
        read: u64,
        result: Result<(Vec<CoreProject>, CoreSortMode), SessionError>,
    ) {
        if read != self.list.folders.projects_read || !self.is_connected() {
            return;
        }
        match result {
            Ok((projects, mode)) => {
                self.emit(CoreEvent::ProjectsLoaded {
                    projects: projects.iter().cloned().map(Into::into).collect(),
                    sort_mode: match mode {
                        CoreSortMode::Alphabetical => ProjectSortMode::Alphabetical,
                        CoreSortMode::Manual => ProjectSortMode::Manual,
                    },
                });
                let known: BTreeSet<String> = projects.iter().map(folder_id).collect();
                let folders = &mut self.list.folders;
                folders.pages.retain(|folder, _| known.contains(folder));
                folders.projects = Some(projects);
                self.read_open_folders();
                self.report_folders();
            }
            Err(error) => {
                let error = CoreError::from(error);
                if error.requires_sign_in() {
                    self.sign_in_lost(error);
                } else {
                    self.emit(CoreEvent::ProjectsFailed { error });
                }
            }
        }
    }

    /// The sidebar shows `open` expanded: read each one's first page that is not loaded yet.
    pub(crate) fn set_open_folders(&mut self, open: BTreeSet<String>) {
        self.list.folders.open = open;
        self.read_open_folders();
        self.report_folders();
    }

    /// Reads `project`'s first page, or its next once that is loaded; nothing while one loads or
    /// once every member is loaded.
    pub(crate) fn load_folder(&mut self, project: CoreProject) {
        let folder = folder_id(&project);
        let pages = self.list.folders.pages.entry(folder.clone()).or_default();
        pages.project = Some(project);
        let read = match (pages.loaded, pages.reading, &pages.next_cursor) {
            (_, Some((_, true)), _) | (true, _, None) => return,
            (false, _, _) => FolderRead::First,
            (true, _, Some(_)) => FolderRead::Next,
        };
        self.read_folder(&folder, read);
        self.report_folders();
    }

    fn read_open_folders(&mut self) {
        let open: Vec<String> = self.list.folders.open.iter().cloned().collect();
        for folder in open {
            let pages = self.list.folders.pages.get(&folder);
            if pages.is_some_and(|pages| pages.loaded || pages.reading.is_some()) {
                continue;
            }
            if self.list.folders.project(&folder).is_some() {
                self.read_folder(&folder, FolderRead::First);
            }
        }
    }

    /// A list reload: the open loaded folders read their first page again, closed ones are
    /// forgotten.
    pub(crate) fn refresh_folders(&mut self) {
        let folders = &mut self.list.folders;
        let open = &folders.open;
        folders
            .pages
            .retain(|folder, pages| open.contains(folder) && pages.loaded);
        let loaded: Vec<String> = folders.pages.keys().cloned().collect();
        for folder in loaded {
            self.read_folder(&folder, FolderRead::Again);
        }
        self.report_folders();
    }

    fn read_folder(&mut self, folder: &str, read: FolderRead) {
        if !self.is_connected() {
            return;
        }
        let folders = &mut self.list.folders;
        let project = folders
            .pages
            .get(folder)
            .and_then(|pages| pages.project.clone())
            .or_else(|| folders.project(folder));
        let Some(project) = project else {
            return;
        };
        folders.next_read = folders.next_read.wrapping_add(1);
        let token = folders.next_read;
        let pages = folders.pages.entry(folder.to_owned()).or_default();
        pages.project = Some(project.clone());
        let after = (read == FolderRead::Next)
            .then(|| pages.next_cursor.clone())
            .flatten();
        pages.reading = Some((token, read != FolderRead::Again));
        let sessions = Arc::clone(&self.sessions);
        let tx = self.sender();
        let folder = folder.to_owned();
        self.host.spawn(async move {
            let result = sessions
                .project_session_page(&project.name, after.as_deref(), PROJECT_PAGE_LIMIT)
                .await;
            post(
                &tx,
                Msg::List(ListMsg::FolderLoaded {
                    folder,
                    token,
                    read,
                    result,
                }),
            );
        });
    }

    pub(crate) fn folder_loaded(
        &mut self,
        folder: &str,
        token: u64,
        read: FolderRead,
        result: Result<SessionPage, SessionError>,
    ) {
        let connected = self.is_connected();
        let Some(pages) = self.list.folders.pages.get_mut(folder) else {
            return;
        };
        if pages.reading.is_none_or(|(current, _)| current != token) || !connected {
            return;
        }
        pages.reading = None;
        match result {
            Ok(page) => {
                pages.loaded = true;
                pages.next_cursor = page.next_cursor;
                if read == FolderRead::Next {
                    pages.rows.extend(page.sessions);
                } else {
                    pages.rows = page.sessions;
                }
                self.update_watch();
            }
            Err(error) => {
                let error = CoreError::from(error);
                if error.requires_sign_in() {
                    self.sign_in_lost(error);
                    return;
                }
                self.emit(CoreEvent::ProjectFolderFailed {
                    folder_id: folder.to_owned(),
                    error,
                });
            }
        }
        self.report_folders();
    }

    /// Tells the app every folder's pages, when any changed.
    pub(crate) fn report_folders(&mut self) {
        let paging = self.list.folders.paging();
        if paging == self.list.folders.reported {
            return;
        }
        self.list.folders.reported.clone_from(&paging);
        self.emit(CoreEvent::ProjectFoldersChanged { folders: paging });
    }
}

#[cfg(test)]
#[path = "project_driver_tests.rs"]
mod tests;
