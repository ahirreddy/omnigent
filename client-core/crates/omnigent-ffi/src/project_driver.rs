//! The sidebar's projects and the pages of its open folders, read by the engine as soon as the
//! connection is up rather than after the app draws its first frame.
//!
//! The projects and their sort order come at once, beside the list's first page, then the first
//! page of each folder the sidebar shows open (the web's `?project=` read). A list reload reads
//! the open folders again; their rows stay shown meanwhile, and folders that are closed by then
//! are forgotten.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use omnigent_core::SessionError;
use omnigent_core::message_cache::SavedProjects;
use omnigent_core::project_settings::ProjectSortMode as CoreSortMode;
use omnigent_core::projects::ProjectSummary as CoreProject;
use omnigent_core::sessions::{SessionPage, SessionSummary};
use omnigent_protocol::SessionListItem;

use crate::engine::{Engine, Msg};
use crate::errors::CoreError;
use crate::events::CoreEvent;
use crate::list_driver::ListMsg;
use crate::runtime::post;
use crate::sessions::ProjectSummary;
use crate::sidebar::ProjectSortMode;

/// How many sessions one folder page reads, as the web's folder.
const PROJECT_PAGE_LIMIT: u32 = 20;

/// The id of `project`'s sidebar folder: its first-class id, else its name for a label-only
/// project.
#[must_use]
#[uniffi::export]
pub fn project_folder_id(project: ProjectSummary) -> String {
    folder_id(&project.into())
}

/// The app's name for how projects sort.
pub(crate) const fn sort_mode(mode: CoreSortMode) -> ProjectSortMode {
    match mode {
        CoreSortMode::Alphabetical => ProjectSortMode::Alphabetical,
        CoreSortMode::Manual => ProjectSortMode::Manual,
    }
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
    /// The projects last read on any connection, or saved: they name the open folders' first
    /// reads until this connection's projects land, so those reads need not wait for them.
    known: Vec<CoreProject>,
    /// This connection's projects read answered.
    projects_answered: bool,
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
    /// The same pages' rows as the server sent them, for the saved list.
    saved: Vec<SessionListItem>,
}

impl Folders {
    /// A new connection: the open folders and the known projects stay, nothing read on the old
    /// one does.
    pub(crate) fn for_new_connection(&mut self) -> Self {
        Self {
            open: std::mem::take(&mut self.open),
            known: std::mem::take(&mut self.known),
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

    /// The loaded folders' rows as the server sent them.
    pub(crate) fn saved_rows(&self) -> impl Iterator<Item = &SessionListItem> {
        self.pages.values().flat_map(|pages| pages.saved.iter())
    }

    /// Takes the saved projects as known, when no read has made any known.
    pub(crate) fn know(&mut self, saved: &[CoreProject]) {
        if self.known.is_empty() {
            self.known = saved.to_vec();
        }
    }

    /// Another account connected: the projects known were the last one's.
    pub(crate) fn forget_known(&mut self) {
        self.known.clear();
    }

    /// Whether this connection's projects read, and the first read of each open folder it or
    /// the known projects name, have answered.
    pub(crate) fn first_reads_answered(&self) -> bool {
        self.projects_answered
            && self.open.iter().all(|folder| {
                self.pages
                    .get(folder)
                    .is_none_or(|pages| pages.reading.is_none())
            })
    }

    fn project(&self, folder: &str) -> Option<CoreProject> {
        self.projects
            .as_ref()
            .unwrap_or(&self.known)
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
        self.list.folders.projects_answered = true;
        match result {
            Ok((projects, mode)) => {
                self.emit(CoreEvent::ProjectsLoaded {
                    projects: projects.iter().cloned().map(Into::into).collect(),
                    sort_mode: sort_mode(mode),
                });
                let known: BTreeSet<String> = projects.iter().map(folder_id).collect();
                let folders = &mut self.list.folders;
                folders.pages.retain(|folder, _| known.contains(folder));
                // A folder read by a name its project no longer has reads its first page again.
                for (folder, pages) in &mut folders.pages {
                    let fresh = projects
                        .iter()
                        .find(|project| folder_id(project) == *folder);
                    let read = pages.project.as_ref();
                    if let (Some(fresh), Some(read)) = (fresh, read)
                        && fresh.name != read.name
                    {
                        pages.project = Some(fresh.clone());
                        pages.loaded = false;
                        pages.reading = None;
                        pages.next_cursor = None;
                    }
                }
                folders.known.clone_from(&projects);
                folders.projects = Some(projects.clone());
                self.saved_projects(SavedProjects {
                    projects,
                    sort: mode,
                });
                self.read_open_folders();
                self.report_folders();
            }
            Err(error) => {
                let error = CoreError::from(error);
                if error.requires_sign_in() {
                    self.sign_in_lost(error);
                    return;
                }
                self.emit(CoreEvent::ProjectsFailed { error });
            }
        }
        self.release_held_page(false);
    }

    /// The sidebar shows `open` expanded: read each one's first page that is not loaded yet.
    pub(crate) fn set_open_folders(&mut self, open: BTreeSet<String>) {
        self.list.folders.open = open;
        self.read_open_folders();
        self.report_folders();
    }

    /// Reads `project`'s first page, or with `next` the page after the loaded ones (its first
    /// while none is loaded); nothing while one loads, once that page is loaded, or once every
    /// member is. A first page the core read already answers a view that asks for it.
    pub(crate) fn load_folder(&mut self, project: CoreProject, next: bool) {
        let folder = folder_id(&project);
        let pages = self.list.folders.pages.entry(folder.clone()).or_default();
        pages.project = Some(project);
        let read = match (pages.loaded, pages.reading, &pages.next_cursor) {
            (_, Some((_, true)), _) | (true, _, None) => return,
            (false, _, _) => FolderRead::First,
            (true, _, Some(_)) if next => FolderRead::Next,
            (true, _, Some(_)) => return,
        };
        self.read_folder(&folder, read);
        self.report_folders();
    }

    /// Reads the first page of each open folder that is neither loaded nor loading, by the
    /// projects of this connection or, before they land, the known ones.
    pub(crate) fn read_open_folders(&mut self) {
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
                    pages.saved.extend(page.rows.iter().cloned());
                } else {
                    pages.rows = page.sessions;
                    pages.saved.clone_from(&page.rows);
                }
                self.update_watch();
                self.saved_list_more(&page.rows);
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
        self.release_held_page(false);
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
