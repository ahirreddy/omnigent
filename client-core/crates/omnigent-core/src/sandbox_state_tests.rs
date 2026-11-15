//! Tests of `crate::sandbox_state`: the launch as reported, every phase a sandbox passes
//! through, and when each operation applies.

use omnigent_protocol::sessions::{SandboxStage, SandboxStatus};
use serde_json::json;

use super::*;

fn status(stage: &str) -> SandboxStatus {
    SandboxStatus {
        stage: SandboxStage::parse(stage),
        error: (stage == "failed").then(|| "No capacity".to_owned()),
        provider: Some("example".to_owned()),
        details: (stage == "action_required").then(|| "Sign in on your laptop.".to_owned()),
    }
}

fn launch(stage: &str) -> SandboxLaunch {
    SandboxLaunch::of(&status(stage)).unwrap_or_else(|| panic!("{stage} is a launch"))
}

/// An owner's sandbox session on a bound host, with nothing reported yet.
fn owned() -> SandboxSignals {
    SandboxSignals {
        host_sandbox: Some("Modal Sandbox".to_owned()),
        host_id: Some("host-1".to_owned()),
        can_edit: true,
        is_owner: true,
        ..SandboxSignals::default()
    }
}

fn state(signals: &SandboxSignals) -> SandboxState {
    sandbox_state(signals).expect("a sandbox session")
}

fn reason(state: &SandboxState, operation: SandboxOperation) -> Option<&str> {
    state
        .operations
        .iter()
        .find(|candidate| candidate.operation == operation)
        .expect("the operation is listed")
        .unavailable_reason
        .as_deref()
}

fn title(state: &SandboxState, operation: SandboxOperation) -> &str {
    &state
        .operations
        .iter()
        .find(|candidate| candidate.operation == operation)
        .expect("the operation is listed")
        .title
}

#[test]
fn every_launch_stage_has_the_webs_words_and_only_ready_ends_the_launch() {
    let cases = [
        ("provisioning", "Provisioning sandbox", true),
        ("action_required", "Provisioning sandbox", false),
        ("cloning", "Cloning repository", true),
        ("starting", "Connecting host", true),
        ("connecting", "Starting agent", true),
        ("ready", "Ready", false),
        ("failed", "Sandbox launch failed", false),
    ];
    for (wire, label, in_progress) in cases {
        let stage = LaunchStage::of(&SandboxStage::parse(wire)).expect(wire);
        assert_eq!(stage.wire(), wire);
        assert_eq!(stage.label(), label, "{wire}");
        assert_eq!(stage.is_in_progress(), in_progress, "{wire}");
    }
    assert_eq!(LaunchStage::of(&SandboxStage::parse("brand_new")), None);
    assert_eq!(SandboxLaunch::of(&status("brand_new")), None);
    assert_eq!(launch("ready").unfinished(), None);
    assert_eq!(launch("failed").unfinished(), Some(launch("failed")));
    assert_eq!(launch("cloning").unfinished(), Some(launch("cloning")));
}

#[test]
fn a_launch_keeps_its_provider_details_and_error_and_survives_saving() {
    let waiting = launch("action_required");
    assert_eq!(waiting.stage, LaunchStage::ActionRequired);
    assert_eq!(waiting.provider.as_deref(), Some("example"));
    assert_eq!(waiting.details.as_deref(), Some("Sign in on your laptop."));
    assert_eq!(waiting.error, None);
    let failed = launch("failed");
    assert_eq!(failed.error.as_deref(), Some("No capacity"));
    for saved in [waiting, failed, launch("cloning"), launch("ready")] {
        assert_eq!(
            SandboxLaunch::from_value(&saved.to_value()),
            Ok(Some(saved))
        );
    }
    // A stage saved by a newer client is no launch here.
    assert_eq!(
        SandboxLaunch::from_value(&json!({"stage": "brand_new"})),
        Ok(None)
    );
    for malformed in [
        json!("provisioning"),
        json!({}),
        json!({"stage": 1}),
        json!({"stage": "failed", "provider": 1}),
        json!({"stage": "failed", "details": 1}),
        json!({"stage": "failed", "error": 1}),
    ] {
        assert!(
            SandboxLaunch::from_value(&malformed).is_err(),
            "{malformed}"
        );
    }
}

#[test]
fn a_profile_is_named_only_when_the_session_gives_its_name_and_provider() {
    let named = json!({"id": "gpu", "name": "GPU box", "provider": "modal", "revision": "r1"});
    assert_eq!(
        SandboxProfileName::of(&named),
        Some(SandboxProfileName {
            provider: "modal".to_owned(),
            name: "GPU box".to_owned(),
        })
    );
    assert_eq!(SandboxProfileName::of(&json!({"name": "GPU box"})), None);
    assert_eq!(SandboxProfileName::of(&json!({"provider": "modal"})), None);
    assert_eq!(
        SandboxProfileName::of(&json!({"provider": "modal", "name": ""})),
        None
    );
    assert_eq!(SandboxProfileName::of(&json!("gpu")), None);
}

#[test]
fn a_session_without_a_sandbox_has_no_state() {
    let machine = SandboxSignals {
        host_id: Some("mac".to_owned()),
        host_online: Some(true),
        runner_online: Some(true),
        can_edit: true,
        is_owner: true,
        ..SandboxSignals::default()
    };
    assert_eq!(sandbox_state(&machine), None);
    assert_eq!(sandbox_state(&SandboxSignals::default()), None);
    // Resumable without a host says nothing about a sandbox.
    let unbound = SandboxSignals {
        host_resumable: Some(true),
        ..SandboxSignals::default()
    };
    assert_eq!(sandbox_state(&unbound), None);
}

#[test]
fn each_sign_of_a_sandbox_is_enough_and_names_its_provider() {
    let launching = SandboxSignals {
        launch: Some(launch("provisioning")),
        ..SandboxSignals::default()
    };
    assert_eq!(state(&launching).title, "Example Sandbox");
    let profiled = SandboxSignals {
        profile: Some(SandboxProfileName {
            provider: "daytona".to_owned(),
            name: "GPU box".to_owned(),
        }),
        ..SandboxSignals::default()
    };
    let shown = state(&profiled);
    assert_eq!(shown.title, "Daytona Sandbox");
    assert_eq!(shown.profile.as_deref(), Some("GPU box"));
    assert_eq!(state(&owned()).title, "Modal Sandbox");
    // The launch names the provider before the profile and the host do.
    let all = SandboxSignals {
        launch: Some(launch("cloning")),
        profile: profiled.profile,
        ..owned()
    };
    assert_eq!(state(&all).title, "Example Sandbox");
    let resumable = SandboxSignals {
        host_sandbox: None,
        host_resumable: Some(true),
        ..owned()
    };
    assert_eq!(state(&resumable).title, "Sandbox");
    let unnamed = SandboxSignals {
        host_sandbox: Some(String::new()),
        ..owned()
    };
    assert_eq!(state(&unnamed).title, "Sandbox");
    // A launch that names no provider leaves the naming to the profile, then the host.
    let unnamed_launch = SandboxLaunch {
        provider: Some(String::new()),
        ..launch("cloning")
    };
    let by_host = SandboxSignals {
        launch: Some(unnamed_launch),
        ..owned()
    };
    assert_eq!(state(&by_host).title, "Modal Sandbox");
}

#[test]
fn a_launch_moves_through_its_stages_then_the_sandbox_runs() {
    let mut signals = SandboxSignals {
        can_edit: true,
        is_owner: true,
        ..SandboxSignals::default()
    };
    let stages = [
        (
            "provisioning",
            "Provisioning sandbox",
            LaunchStage::Provisioning,
        ),
        ("cloning", "Cloning repository", LaunchStage::Cloning),
        ("starting", "Connecting host", LaunchStage::Starting),
        ("connecting", "Starting agent", LaunchStage::Connecting),
    ];
    for (wire, summary, stage) in stages {
        signals.launch = Some(launch(wire));
        let shown = state(&signals);
        assert_eq!(shown.phase, SandboxPhase::Launching, "{wire}");
        assert_eq!(shown.stage, Some(stage));
        assert_eq!(shown.summary, summary);
        assert_eq!((shown.details, shown.error, shown.hint), (None, None, None));
    }
    // `ready` ends the launch; the host and runner it bound now speak for the sandbox, which
    // the finished launch still marks as one before the host list names it.
    signals.launch = Some(launch("ready"));
    signals.host_id = Some("host-1".to_owned());
    signals.host_online = Some(true);
    signals.runner_online = Some(true);
    let running = state(&signals);
    assert_eq!(running.phase, SandboxPhase::Running);
    assert_eq!(running.stage, None);
    assert_eq!(running.title, "Example Sandbox");
    assert_eq!(running.summary, "Running");
    assert_eq!(
        (running.host_online, running.runner_online),
        (Some(true), Some(true))
    );
}

#[test]
fn a_launch_that_waits_or_fails_says_what_and_why() {
    let waiting = state(&SandboxSignals {
        launch: Some(launch("action_required")),
        ..owned()
    });
    assert_eq!(waiting.phase, SandboxPhase::ActionRequired);
    assert_eq!(waiting.summary, "Provisioning sandbox");
    assert_eq!(waiting.details.as_deref(), Some("Sign in on your laptop."));
    assert_eq!(waiting.error, None);
    let failed = state(&SandboxSignals {
        launch: Some(launch("failed")),
        ..owned()
    });
    assert_eq!(failed.phase, SandboxPhase::Failed);
    assert_eq!(failed.summary, "Sandbox launch failed");
    assert_eq!(failed.error.as_deref(), Some("No capacity"));
    assert_eq!(failed.details, None);
}

/// A launched sandbox reporting this liveness.
fn launched(host: Option<bool>, runner: Option<bool>, resumable: bool, turn: bool) -> SandboxState {
    state(&SandboxSignals {
        host_online: host,
        runner_online: runner,
        host_resumable: Some(resumable),
        turn_active: turn,
        ..owned()
    })
}

#[test]
fn a_launched_sandbox_is_running_asleep_or_offline_as_the_server_reports() {
    let running = launched(Some(true), Some(true), false, false);
    assert_eq!(running.phase, SandboxPhase::Running);
    assert_eq!((running.summary.as_str(), running.hint), ("Running", None));
    // The runner answers for itself even when the host has not reported.
    assert_eq!(
        launched(None, Some(true), false, false).phase,
        SandboxPhase::Running
    );
    let agent_asleep = launched(Some(true), Some(false), false, false);
    assert_eq!(agent_asleep.phase, SandboxPhase::AgentAsleep);
    assert_eq!(agent_asleep.summary, "Agent asleep");
    assert_eq!(
        agent_asleep.hint.as_deref(),
        Some("The next message starts the agent.")
    );
    let asleep = launched(Some(false), Some(false), true, false);
    assert_eq!(asleep.phase, SandboxPhase::Asleep);
    assert_eq!(asleep.summary, "Asleep");
    assert_eq!(asleep.hint.as_deref(), Some("The next message wakes it."));
    let offline = launched(Some(false), Some(false), false, false);
    assert_eq!(offline.phase, SandboxPhase::Offline);
    assert_eq!(offline.summary, "Offline");
    assert_eq!(
        offline.hint.as_deref(),
        Some("The next message launches a new sandbox.")
    );
}

#[test]
fn a_turn_wakes_a_resting_sandbox_and_silence_is_not_a_state() {
    for (host, resumable) in [(false, true), (false, false), (true, false)] {
        let waking = launched(Some(host), Some(false), resumable, true);
        assert_eq!(waking.phase, SandboxPhase::Waking, "{host} {resumable}");
        assert_eq!((waking.summary.as_str(), waking.hint), ("Waking", None));
    }
    let unknown = launched(None, None, true, false);
    assert_eq!(unknown.phase, SandboxPhase::Unknown);
    assert_eq!(unknown.summary, "Not reported yet");
    assert_eq!(unknown.hint, None);
    // A sandbox session whose launch state is gone and that never bound a host.
    let unbound = state(&SandboxSignals {
        host_id: None,
        ..owned()
    });
    assert_eq!(unbound.phase, SandboxPhase::Offline);
    assert_eq!(unbound.hint, None);
}

#[test]
fn wake_applies_to_a_sandbox_at_rest_under_the_title_that_fits() {
    let wake = SandboxOperation::Wake;
    let at = |signals: SandboxSignals| state(&signals);
    let asleep = at(SandboxSignals {
        host_online: Some(false),
        host_resumable: Some(true),
        ..owned()
    });
    assert_eq!(
        (title(&asleep, wake), reason(&asleep, wake)),
        ("Wake", None)
    );
    let agent_asleep = at(SandboxSignals {
        host_online: Some(true),
        runner_online: Some(false),
        ..owned()
    });
    assert_eq!(
        (title(&agent_asleep, wake), reason(&agent_asleep, wake)),
        ("Start Agent", None)
    );
    let offline = at(SandboxSignals {
        host_online: Some(false),
        ..owned()
    });
    assert_eq!(
        (title(&offline, wake), reason(&offline, wake)),
        ("Launch Again", None)
    );
    let failed = at(SandboxSignals {
        launch: Some(launch("failed")),
        host_online: Some(false),
        ..owned()
    });
    assert_eq!(
        (title(&failed, wake), reason(&failed, wake)),
        ("Retry Launch", None)
    );
    let operation = &asleep.operations[0];
    assert!(!operation.is_destructive);
    assert!(operation.help.contains("as the next message would"));
}

#[test]
fn wake_says_why_it_does_not_apply() {
    let wake = SandboxOperation::Wake;
    let at = |signals: SandboxSignals| state(&signals);
    // A first launch that failed bound no host, and the server has nothing to retry.
    let never_bound = at(SandboxSignals {
        launch: Some(launch("failed")),
        host_id: Some(String::new()),
        ..owned()
    });
    assert_eq!(
        reason(&never_bound, wake),
        Some("This session has no sandbox to start. Create a new session instead.")
    );
    let refused = [
        (
            SandboxSignals {
                launch: Some(launch("cloning")),
                ..owned()
            },
            "The sandbox is already launching.",
        ),
        (
            SandboxSignals {
                launch: Some(launch("action_required")),
                ..owned()
            },
            "The sandbox is already launching.",
        ),
        (
            SandboxSignals {
                host_online: Some(false),
                turn_active: true,
                ..owned()
            },
            "The sandbox is already waking.",
        ),
        (
            SandboxSignals {
                runner_online: Some(true),
                ..owned()
            },
            "The sandbox is already running.",
        ),
        (owned(), "The server has not reported this sandbox yet."),
        (
            SandboxSignals {
                host_online: Some(false),
                can_edit: false,
                ..owned()
            },
            VIEW_ONLY_REASON,
        ),
    ];
    for (signals, expected) in refused {
        let shown = at(signals);
        assert_eq!(reason(&shown, wake), Some(expected), "{:?}", shown.phase);
    }
}

#[test]
fn stop_applies_to_the_owners_running_agent_only() {
    let stop = SandboxOperation::Stop;
    let running = state(&SandboxSignals {
        host_online: Some(true),
        runner_online: Some(true),
        ..owned()
    });
    assert_eq!(
        (title(&running, stop), reason(&running, stop)),
        ("Stop Agent", None)
    );
    let operation = &running.operations[1];
    assert!(operation.is_destructive);
    assert!(operation.help.contains("sleeps on its own"));
    let refused = [
        (
            SandboxSignals {
                runner_online: Some(true),
                is_owner: false,
                ..owned()
            },
            OWNER_ONLY_REASON,
        ),
        (
            SandboxSignals {
                launch: Some(launch("starting")),
                ..owned()
            },
            "The agent has not started yet.",
        ),
        (
            SandboxSignals {
                launch: Some(launch("action_required")),
                ..owned()
            },
            "The agent has not started yet.",
        ),
        (
            SandboxSignals {
                host_online: Some(true),
                turn_active: true,
                ..owned()
            },
            "The agent has not started yet.",
        ),
        (
            SandboxSignals {
                host_online: Some(false),
                host_resumable: Some(true),
                ..owned()
            },
            "The agent is not running.",
        ),
        (
            SandboxSignals {
                launch: Some(launch("failed")),
                ..owned()
            },
            "The agent is not running.",
        ),
    ];
    for (signals, expected) in refused {
        let shown = state(&signals);
        assert_eq!(reason(&shown, stop), Some(expected), "{:?}", shown.phase);
    }
}
