//! A project from a repository: validation, clone, the project's config and the web's words
//! for each failure.

use futures::executor::block_on;
use serde_json::json;

use super::super::SessionError;
use super::super::test_support::{Reply, RouteTransport, connected, path_of};
use super::{
    FolderProject, ProjectTarget, RepositoryProject, clone_failure_message,
    default_clone_destination, directory_failure_message, is_single_path_component,
    project_repository_problem,
};

fn request(target: ProjectTarget) -> RepositoryProject {
    RepositoryProject {
        name: " Garden ".into(),
        icon: Some("🌱".into()),
        target,
        url: "https://github.com/org/app".into(),
        branch: "main".into(),
        destination: "~/app".into(),
    }
}

fn reason(error: SessionError) -> String {
    match error {
        SessionError::InvalidInput { reason } => reason,
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn a_host_project_clones_first_then_saves_the_checkout() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        "/v1/hosts/host_1/repositories/clone",
        r#"{"object":"repository","path":"/Users/me/app"}"#,
    );
    core.transport().ok(
        "/v1/projects",
        r#"{"id":"p9","object":"project","name":"Garden","created_at":1,"updated_at":1}"#,
    );
    let project =
        block_on(core.create_repository_project(&request(ProjectTarget::Host("host_1".into()))))
            .unwrap();
    assert_eq!(project.name, "Garden");
    let writes = core.transport().writes();
    assert_eq!(
        writes.iter().map(path_of).collect::<Vec<_>>(),
        ["/v1/hosts/host_1/repositories/clone", "/v1/projects"]
    );
    assert_eq!(
        core.transport().write_bodies(),
        [
            json!({"url": "https://github.com/org/app", "branch": "main", "path": "~/app"}),
            json!({"name": "Garden", "config": {
                "icon": "🌱", "host_id": "host_1", "workspace": "/Users/me/app",
                "repository": {"url": "https://github.com/org/app", "branch": "main"}}}),
        ]
    );
}

#[test]
fn a_sandbox_project_saves_the_repository_without_cloning() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        "/v1/projects",
        r#"{"id":"p9","object":"project","name":"Garden"}"#,
    );
    let mut sandbox = request(ProjectTarget::Sandbox(Some("modal".into())));
    sandbox.branch = String::new();
    sandbox.icon = None;
    block_on(core.create_repository_project(&sandbox)).unwrap();
    assert_eq!(
        core.transport().write_bodies(),
        [json!({"name": "Garden", "config": {
            "host_id": "__sandbox__", "sandbox_provider": "modal",
            "repository": {"url": "https://github.com/org/app"}}})]
    );
}

#[test]
fn a_failed_clone_creates_nothing_and_says_why() {
    let core = connected(RouteTransport::local());
    core.transport().respond(
        Some("POST"),
        "/v1/hosts/host_1/repositories/clone",
        None,
        Reply::json(
            409,
            r#"{"detail":"host clone failed: /Users/me/app already exists"}"#,
        ),
    );
    let error =
        block_on(core.create_repository_project(&request(ProjectTarget::Host("host_1".into()))))
            .unwrap_err();
    assert!(reason(error).starts_with("That destination already exists."));
    assert!(
        core.transport()
            .writes()
            .iter()
            .all(|request| path_of(request) != "/v1/projects")
    );
}

#[test]
fn a_refused_create_after_a_clone_names_the_checkout() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        "/v1/hosts/host_1/repositories/clone",
        r#"{"object":"repository","path":"/Users/me/app"}"#,
    );
    core.transport().respond(
        Some("POST"),
        "/v1/projects",
        None,
        Reply::json(409, r#"{"detail":"exists"}"#),
    );
    let error =
        block_on(core.create_repository_project(&request(ProjectTarget::Host("host_1".into()))))
            .unwrap_err();
    assert_eq!(
        reason(error),
        "A project with this name already exists. Use a different name. The repository is \
         already checked out at /Users/me/app."
    );
}

#[test]
fn bad_inputs_are_refused_before_any_request() {
    let core = connected(RouteTransport::local());
    let mut bad = request(ProjectTarget::Host("host_1".into()));
    bad.url = "not a url".into();
    assert_eq!(
        reason(block_on(core.create_repository_project(&bad)).unwrap_err()),
        "Enter a repository URL like https://github.com/org/repo."
    );
    let mut nowhere = request(ProjectTarget::Host("host_1".into()));
    nowhere.destination = " ".into();
    assert_eq!(
        reason(block_on(core.create_repository_project(&nowhere)).unwrap_err()),
        "Choose where to clone the repository."
    );
    assert_eq!(core.transport().writes(), []);
}

#[test]
fn repository_problems_and_defaults_follow_the_web() {
    assert_eq!(project_repository_problem("", ""), None);
    assert_eq!(
        project_repository_problem("", "main").as_deref(),
        Some("Add the repository this branch belongs to.")
    );
    assert_eq!(
        project_repository_problem("https://github.com/org/app", "bad branch").as_deref(),
        Some("Enter a valid branch name or leave it blank for the default branch.")
    );
    assert_eq!(
        project_repository_problem("git@github.com:org/app.git", ""),
        None
    );
    assert_eq!(
        default_clone_destination("https://github.com/org/app.git").as_deref(),
        Some("~/app")
    );
    assert_eq!(
        clone_failure_message("409: Update this host to clone repositories"),
        "This host is too old to clone repositories. Update omnigent on it and try again."
    );
    assert_eq!(
        clone_failure_message("something else"),
        "The repository couldn\u{2019}t be cloned. Check the details and try again."
    );
}

#[test]
fn a_folder_project_names_its_host_and_working_directory() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        "/v1/projects",
        r#"{"id":"p9","object":"project","name":"Garden","created_at":1,"updated_at":1}"#,
    );
    let mut project = FolderProject {
        name: " Garden ".into(),
        icon: Some("🌱".into()),
        host_id: Some("host_1".into()),
        workspace: Some("/Users/me/garden".into()),
    };
    block_on(core.create_folder_project(&project)).unwrap();
    project.workspace = None;
    block_on(core.create_folder_project(&project)).unwrap();
    project.host_id = None;
    project.icon = None;
    block_on(core.create_folder_project(&project)).unwrap();
    assert_eq!(
        core.transport().write_bodies(),
        [
            json!({"name": "Garden", "config": {
                "icon": "🌱", "host_id": "host_1", "workspace": "/Users/me/garden"}}),
            json!({"name": "Garden", "config": {"icon": "🌱", "host_id": "host_1"}}),
            json!({"name": "Garden"}),
        ]
    );
}

#[test]
fn a_project_folder_is_made_in_home_and_failures_use_the_webs_words() {
    let core = connected(RouteTransport::local());
    core.transport().ok(
        "/v1/hosts/host_1/directories",
        r#"{"object":"directory","path":"/Users/me/Garden"}"#,
    );
    assert_eq!(
        block_on(core.create_project_folder("host_1", " Garden ")).unwrap(),
        "/Users/me/Garden"
    );
    assert_eq!(
        core.transport().write_bodies(),
        [json!({"path": "~/Garden"})]
    );
    assert_eq!(
        reason(block_on(core.create_project_folder("host_1", "a/b")).unwrap_err()),
        "Use a project name without slashes or dot segments to create a folder."
    );
    let refused = connected(RouteTransport::local());
    refused.transport().respond(
        Some("POST"),
        "/v1/hosts/host_1/directories",
        None,
        Reply::json(409, r#"{"detail":"directory already exists"}"#),
    );
    assert_eq!(
        reason(block_on(refused.create_project_folder("host_1", "Garden")).unwrap_err()),
        "That folder already exists. Choose a different folder."
    );
}

#[test]
fn folder_names_and_directory_failures_follow_the_web() {
    assert!(is_single_path_component("Garden 2"));
    for bad in [".", "..", "a/b", "a\\b", "a\0b"] {
        assert!(!is_single_path_component(bad), "{bad}");
    }
    assert_eq!(
        directory_failure_message("Host is offline"),
        "The host is offline. Reconnect it and try again."
    );
    assert_eq!(
        directory_failure_message("parent is a file"),
        "That folder can\u{2019}t be created. Uncheck the box to choose another location."
    );
    assert_eq!(
        directory_failure_message("boom"),
        "The folder couldn\u{2019}t be created. Check the host and try again."
    );
}
