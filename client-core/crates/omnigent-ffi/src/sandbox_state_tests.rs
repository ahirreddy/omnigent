//! The sandbox records convert both ways, and the exported rules answer as the core's do.

use omnigent_core::config::session::SessionConfiguration as CoreConfiguration;
use omnigent_core::reducer as core_reducer;

use super::core;
use super::*;
use crate::configuration::SessionConfiguration;
use crate::transcript::SessionHeader;

fn failed_launch() -> core::SandboxLaunch {
    core::SandboxLaunch {
        stage: core::LaunchStage::Failed,
        provider: Some("example".into()),
        details: Some("Sign in on your laptop.".into()),
        error: Some("No capacity".into()),
    }
}

fn signals() -> SandboxSignals {
    SandboxSignals {
        launch: None,
        profile: Some(SandboxProfileName {
            provider: "modal".into(),
            name: "GPU box".into(),
        }),
        host_sandbox: Some("Modal Sandbox".into()),
        host_id: Some("host-1".into()),
        host_online: Some(true),
        runner_online: Some(true),
        host_resumable: Some(true),
        turn_active: false,
        can_edit: true,
        is_owner: true,
    }
}

#[test]
fn every_stage_converts_both_ways_and_has_its_words() {
    use core::LaunchStage as L;
    for (theirs, ours, label) in [
        (
            L::Provisioning,
            SandboxLaunchStage::Provisioning,
            "Provisioning sandbox",
        ),
        (
            L::ActionRequired,
            SandboxLaunchStage::ActionRequired,
            "Provisioning sandbox",
        ),
        (
            L::Cloning,
            SandboxLaunchStage::Cloning,
            "Cloning repository",
        ),
        (L::Starting, SandboxLaunchStage::Starting, "Connecting host"),
        (
            L::Connecting,
            SandboxLaunchStage::Connecting,
            "Starting agent",
        ),
        (L::Ready, SandboxLaunchStage::Ready, "Ready"),
        (
            L::Failed,
            SandboxLaunchStage::Failed,
            "Sandbox launch failed",
        ),
    ] {
        assert_eq!(SandboxLaunchStage::from(theirs), ours);
        assert_eq!(L::from(ours), theirs);
        assert_eq!(sandbox_launch_label(ours), label);
    }
}

#[test]
fn every_phase_and_operation_converts() {
    use core::SandboxPhase as P;
    for (theirs, ours) in [
        (P::Launching, SandboxPhase::Launching),
        (P::ActionRequired, SandboxPhase::ActionRequired),
        (P::Failed, SandboxPhase::Failed),
        (P::Running, SandboxPhase::Running),
        (P::Waking, SandboxPhase::Waking),
        (P::AgentAsleep, SandboxPhase::AgentAsleep),
        (P::Asleep, SandboxPhase::Asleep),
        (P::Offline, SandboxPhase::Offline),
        (P::Unknown, SandboxPhase::Unknown),
    ] {
        assert_eq!(SandboxPhase::from(theirs), ours);
    }
    assert_eq!(
        SandboxOperation::from(core::SandboxOperation::Wake),
        SandboxOperation::Wake
    );
    assert_eq!(
        SandboxOperation::from(core::SandboxOperation::Stop),
        SandboxOperation::Stop
    );
}

#[test]
fn a_launch_and_a_profile_keep_every_field_both_ways() {
    let launch = SandboxLaunch::from(failed_launch());
    assert_eq!(launch.stage, SandboxLaunchStage::Failed);
    assert_eq!(launch.provider.as_deref(), Some("example"));
    assert_eq!(launch.details.as_deref(), Some("Sign in on your laptop."));
    assert_eq!(launch.error.as_deref(), Some("No capacity"));
    assert_eq!(core::SandboxLaunch::from(launch), failed_launch());
    let profile = core::SandboxProfileName {
        provider: "modal".into(),
        name: "GPU box".into(),
    };
    let ours = SandboxProfileName::from(profile.clone());
    assert_eq!(
        (ours.provider.as_str(), ours.name.as_str()),
        ("modal", "GPU box")
    );
    assert_eq!(core::SandboxProfileName::from(ours), profile);
}

#[test]
fn a_header_and_a_configuration_carry_the_launch_and_the_profile() {
    let mut header = core_reducer::SessionHeader::new("conv_a", "Session");
    header.sandbox_launch = Some(failed_launch());
    header.settings = Some(core_reducer::SessionSettings {
        sandbox_profile: Some(core::SandboxProfileName {
            provider: "modal".into(),
            name: "GPU box".into(),
        }),
        ..core_reducer::SessionSettings::default()
    });
    let header = SessionHeader::from(header);
    assert_eq!(header.sandbox_launch, Some(failed_launch().into()));
    let profile = header
        .settings
        .and_then(|settings| settings.sandbox_profile);
    assert_eq!(
        profile.map(|profile| profile.name).as_deref(),
        Some("GPU box")
    );
    assert_eq!(
        SessionHeader::from(core_reducer::SessionHeader::new("conv_a", "Session")).sandbox_launch,
        None
    );

    let configuration = CoreConfiguration {
        sandbox_launch: Some(failed_launch()),
        ..CoreConfiguration::default()
    };
    let ours = SessionConfiguration::from(configuration.clone());
    assert_eq!(ours.sandbox_launch, Some(failed_launch().into()));
    assert_eq!(CoreConfiguration::from(ours), configuration);
}

#[test]
fn the_rules_answer_for_a_sandbox_session_and_not_for_a_machine() {
    let running = sandbox_state(signals()).expect("a sandbox session");
    assert_eq!(running.phase, SandboxPhase::Running);
    assert_eq!(running.stage, None);
    assert_eq!(running.title, "Modal Sandbox");
    assert_eq!(running.profile.as_deref(), Some("GPU box"));
    assert_eq!(running.summary, "Running");
    assert_eq!(
        (running.host_online, running.runner_online),
        (Some(true), Some(true))
    );
    let titles: Vec<(SandboxOperation, &str, bool)> = running
        .operations
        .iter()
        .map(|operation| {
            (
                operation.operation,
                operation.title.as_str(),
                operation.unavailable_reason.is_none(),
            )
        })
        .collect();
    assert_eq!(
        titles,
        [
            (SandboxOperation::Wake, "Wake", false),
            (SandboxOperation::Stop, "Stop Agent", true),
        ]
    );
    assert!(running.operations[1].is_destructive);
    assert!(running.operations[1].help.contains("sleeps on its own"));

    let failed = sandbox_state(SandboxSignals {
        launch: Some(failed_launch().into()),
        runner_online: Some(false),
        host_online: Some(false),
        ..signals()
    })
    .expect("a sandbox session");
    assert_eq!(failed.phase, SandboxPhase::Failed);
    assert_eq!(failed.stage, Some(SandboxLaunchStage::Failed));
    assert_eq!(failed.error.as_deref(), Some("No capacity"));
    assert_eq!((failed.details, failed.hint), (None, None));

    let machine = SandboxSignals {
        profile: None,
        host_sandbox: None,
        host_resumable: None,
        ..signals()
    };
    assert_eq!(sandbox_state(machine), None);
}

#[test]
fn an_operation_and_its_outcome_convert() {
    use core::SandboxOperationOutcome as O;
    for (ours, theirs) in [
        (SandboxOperation::Wake, core::SandboxOperation::Wake),
        (SandboxOperation::Stop, core::SandboxOperation::Stop),
    ] {
        assert_eq!(core::SandboxOperation::from(ours), theirs);
    }
    for (theirs, ours) in [
        (O::Started, SandboxOperationOutcome::Started),
        (O::AlreadyRunning, SandboxOperationOutcome::AlreadyRunning),
        (O::Stopped, SandboxOperationOutcome::Stopped),
    ] {
        assert_eq!(SandboxOperationOutcome::from(theirs), ours);
    }
}

#[test]
fn an_operation_reaches_the_server_and_reports_its_outcome_or_its_refusal() {
    use std::sync::Arc;

    use crate::test_support::{connected, json};
    const EVENTS: &str = "/v1/sessions/conv_a/events";
    let mut harness = connected();
    harness
        .http
        .route(EVENTS, json(202, r#"{"queued":false,"recovered":true}"#));
    let core = Arc::clone(&harness.core);
    let woken = harness.run(async move {
        core.sandbox_operation("conv_a".into(), SandboxOperation::Wake)
            .await
    });
    assert!(
        matches!(woken, Ok(SandboxOperationOutcome::Started)),
        "{woken:?}"
    );
    let core = Arc::clone(&harness.core);
    let stopped = harness.run(async move {
        core.sandbox_operation("conv_a".into(), SandboxOperation::Stop)
            .await
    });
    assert!(
        matches!(stopped, Ok(SandboxOperationOutcome::Stopped)),
        "{stopped:?}"
    );

    harness.http.route(
        EVENTS,
        json(
            503,
            r#"{"error":{"code":"runner_unavailable","message":"No runner is available."}}"#,
        ),
    );
    let core = Arc::clone(&harness.core);
    let refused = harness.run(async move {
        core.sandbox_operation("conv_a".into(), SandboxOperation::Wake)
            .await
    });
    assert!(
        matches!(&refused, Err(CoreError::Session { message, .. })
            if message.contains("No runner is available.")),
        "{refused:?}"
    );
}
