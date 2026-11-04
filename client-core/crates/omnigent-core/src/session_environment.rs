//! Where a session runs, as the sidebar's Environment detail names it (the web's
//! `sessionEnvironmentLabel` and `resolveThisMachineHostId`).

use url::Url;

use crate::creation::CreationHost;
use crate::deeplink::LOOPBACK_HOSTS;

/// A session's environment.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SessionEnvironment {
    /// No host: the server runs it itself ("Local machine").
    LocalMachine,
    /// The host on the device showing the list ("This Mac").
    ThisMachine,
    /// Another machine.
    Remote,
    /// A managed sandbox, named by provider ("Modal Sandbox").
    Sandbox {
        /// The label.
        label: String,
    },
}

/// The new-session label of a sandbox provider: "Modal Sandbox", or "New Sandbox" for none.
#[must_use]
pub fn sandbox_label(provider: Option<&str>) -> String {
    let Some(provider) = provider.filter(|provider| !provider.is_empty()) else {
        return "New Sandbox".to_owned();
    };
    let name = match provider {
        "modal" => "Modal".to_owned(),
        "lakebox" => "Databricks".to_owned(),
        "daytona" => "Daytona".to_owned(),
        "e2b" => "E2B".to_owned(),
        other => {
            let mut characters = other.chars();
            characters.next().map_or_else(String::new, |first| {
                first.to_uppercase().chain(characters).collect()
            })
        }
    };
    format!("{name} Sandbox")
}

/// Whether `server_url` is on this machine (a loopback host).
#[must_use]
pub fn server_is_local(server_url: &str) -> bool {
    Url::parse(server_url)
        .ok()
        .and_then(|url| url.host_str().map(str::to_owned))
        .is_some_and(|host| LOOPBACK_HOSTS.contains(&host.as_str()))
}

/// The host on this device: `known` when the app knows it, else the only online machine of a
/// local server (a guess the web makes too); `None` when unsure.
#[must_use]
pub fn this_machine_host_id<'a>(
    known: Option<&'a str>,
    server_is_local: bool,
    hosts: &'a [CreationHost],
) -> Option<&'a str> {
    if known.is_some() {
        return known;
    }
    let mut online = hosts
        .iter()
        .filter(|host| host.status == "online" && host.sandbox_provider.is_none());
    match (server_is_local, online.next(), online.next()) {
        (true, Some(only), None) => Some(only.host_id.as_str()),
        _ => None,
    }
}

/// Where the session on `host_id` runs.
#[must_use]
pub fn session_environment(
    host_id: Option<&str>,
    hosts: &[CreationHost],
    this_machine: Option<&str>,
) -> SessionEnvironment {
    let Some(host_id) = host_id.filter(|id| !id.is_empty()) else {
        return SessionEnvironment::LocalMachine;
    };
    let host = hosts.iter().find(|host| host.host_id == host_id);
    if let Some(provider) = host.and_then(|host| host.sandbox_provider.as_deref()) {
        return SessionEnvironment::Sandbox {
            label: sandbox_label(Some(provider)),
        };
    }
    if this_machine == Some(host_id) {
        SessionEnvironment::ThisMachine
    } else {
        SessionEnvironment::Remote
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host(id: &str, status: &str, sandbox: Option<&str>) -> CreationHost {
        CreationHost {
            host_id: id.to_owned(),
            name: id.to_owned(),
            status: status.to_owned(),
            sandbox_provider: sandbox.map(str::to_owned),
            configured_harnesses: None,
        }
    }

    #[test]
    fn names_local_this_machine_remote_and_sandboxes() {
        let hosts = [
            host("mac", "online", None),
            host("other", "offline", None),
            host("box", "online", Some("modal")),
        ];
        let this = this_machine_host_id(None, true, &hosts);
        assert_eq!(this, Some("mac"));
        assert_eq!(
            session_environment(None, &hosts, this),
            SessionEnvironment::LocalMachine
        );
        assert_eq!(
            session_environment(Some("mac"), &hosts, this),
            SessionEnvironment::ThisMachine
        );
        assert_eq!(
            session_environment(Some("other"), &hosts, this),
            SessionEnvironment::Remote
        );
        assert_eq!(
            session_environment(Some("unknown"), &hosts, this),
            SessionEnvironment::Remote
        );
        assert_eq!(
            session_environment(Some("box"), &hosts, this),
            SessionEnvironment::Sandbox {
                label: "Modal Sandbox".into()
            }
        );
    }

    #[test]
    fn this_machine_is_a_known_id_or_the_single_online_host_of_a_local_server() {
        let one = [host("mac", "online", None), host("old", "offline", None)];
        let two = [host("a", "online", None), host("b", "online", None)];
        assert_eq!(this_machine_host_id(None, false, &one), None);
        assert_eq!(this_machine_host_id(None, true, &two), None);
        assert_eq!(this_machine_host_id(Some("b"), false, &two), Some("b"));
        assert!(server_is_local("http://127.0.0.1:6767"));
        assert!(server_is_local("http://localhost:6767/omni"));
        assert!(!server_is_local("https://omni.example.com"));
        assert!(!server_is_local("not a url"));
    }

    #[test]
    fn sandbox_labels_follow_the_web() {
        assert_eq!(sandbox_label(Some("lakebox")), "Databricks Sandbox");
        assert_eq!(sandbox_label(Some("acme")), "Acme Sandbox");
        assert_eq!(sandbox_label(None), "New Sandbox");
    }
}
