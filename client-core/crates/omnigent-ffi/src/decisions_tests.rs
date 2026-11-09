//! Decision cards' records in both directions.

#![allow(clippy::too_many_lines, reason = "tables with one case per variant")]

use std::collections::{BTreeMap, HashMap};

use omnigent_core::decisions as core;
use omnigent_protocol::ElicitationValue as CoreValue;

use crate::decisions::{
    DecisionKind, DecisionResponse, EditKind, ElicitationValue, FieldKind, FormField, FormOption,
    PermissionOptions, PersistMode, validate_form,
};

const KINDS: [(core::FieldKind, FieldKind); 6] = [
    (core::FieldKind::Text, FieldKind::Text),
    (core::FieldKind::Number, FieldKind::Number),
    (core::FieldKind::Integer, FieldKind::Integer),
    (core::FieldKind::Boolean, FieldKind::Boolean),
    (core::FieldKind::SingleChoice, FieldKind::SingleChoice),
    (core::FieldKind::MultipleChoice, FieldKind::MultipleChoice),
];

fn option_on_core() -> core::FormOption {
    core::FormOption {
        value: "v".into(),
        label: "Label".into(),
        detail: "More".into(),
    }
}

#[test]
fn every_field_kind_and_a_full_field_map_both_ways() {
    for (on_core, on_ffi) in KINDS {
        assert_eq!(FieldKind::from(on_core), on_ffi);
        assert_eq!(core::FieldKind::from(on_ffi), on_core);
    }

    let mut field = core::FormField::new("key", "Title", core::FieldKind::MultipleChoice);
    field.detail = "Help".into();
    field.required = true;
    field.options = vec![option_on_core()];
    field.allows_custom = true;
    field.is_secret = true;
    field.minimum = Some(1.5);
    field.maximum = Some(2.5);
    field.min_length = Some(3);
    field.max_length = Some(4);
    field.min_items = Some(5);
    field.max_items = Some(6);

    let mapped = FormField::from(field.clone());
    assert_eq!(
        mapped,
        FormField {
            key: "key".into(),
            title: "Title".into(),
            detail: "Help".into(),
            kind: FieldKind::MultipleChoice,
            required: true,
            options: vec![FormOption {
                value: "v".into(),
                label: "Label".into(),
                detail: "More".into(),
            }],
            allows_custom: true,
            is_secret: true,
            minimum: Some(1.5),
            maximum: Some(2.5),
            min_length: Some(3),
            max_length: Some(4),
            min_items: Some(5),
            max_items: Some(6),
        }
    );
    assert_eq!(core::FormField::from(mapped), field);
}

#[test]
fn every_decision_kind_maps() {
    assert_eq!(
        DecisionKind::from(core::DecisionKind::Approval),
        DecisionKind::Approval
    );
    assert_eq!(
        DecisionKind::from(core::DecisionKind::Choice {
            answer_key: "answer".into(),
            options: vec!["a".into()],
        }),
        DecisionKind::Choice {
            answer_key: "answer".into(),
            options: vec!["a".into()],
        }
    );
    let DecisionKind::Form { fields } =
        DecisionKind::from(core::DecisionKind::Form(core::DecisionForm {
            fields: vec![core::FormField::new("k", "T", core::FieldKind::Text)],
        }))
    else {
        panic!("not a form");
    };
    assert_eq!(fields[0].key, "k");
    let reason = core::UnsupportedReason::NonObjectSchema;
    assert_eq!(
        DecisionKind::from(core::DecisionKind::Unsupported {
            reason: reason.clone(),
            external_url: Some("https://x".into()),
        }),
        DecisionKind::Unsupported {
            reason: reason.to_string(),
            external_url: Some("https://x".into()),
        }
    );
}

#[test]
fn persist_modes_and_edit_kinds_map() {
    for (on_core, on_ffi) in [
        (core::PersistMode::Session, PersistMode::Session),
        (core::PersistMode::Always, PersistMode::Always),
    ] {
        assert_eq!(PersistMode::from(on_core), on_ffi);
        assert_eq!(core::PersistMode::from(on_ffi), on_core);
    }
    for (on_core, on_ffi) in [
        (core::FileChangeKind::Create, EditKind::Create),
        (core::FileChangeKind::Modify, EditKind::Modify),
        (core::FileChangeKind::Delete, EditKind::Delete),
        (core::FileChangeKind::Write, EditKind::Write),
    ] {
        assert_eq!(EditKind::from(on_core), on_ffi);
    }
}

#[test]
fn permission_options_keep_every_field() {
    let mapped = PermissionOptions::from(core::PermissionOptions {
        allow_all_edits: true,
        allow_auto_mode: true,
        permission_directories: vec!["/w".into()],
        remember: None,
        plan: Some("the plan".into()),
        command: Some(core::CommandApproval {
            command: "ls".into(),
            cwd: Some("/w".into()),
            reason: Some("look".into()),
        }),
        exec_policy_amendment: Some(vec!["ls".into()]),
        persist_modes: vec![core::PersistMode::Always],
        antigravity: Some(core::AntigravityPermission {
            action_description: Some("act".into()),
            always_allow_pattern: Some("pattern".into()),
        }),
        file_changes: vec![core::FileChange {
            path: "a.rs".into(),
            kind: Some(core::FileChangeKind::Delete),
            lines_added: Some(1),
            lines_removed: Some(2),
        }],
    });
    assert!(mapped.allow_all_edits);
    assert!(mapped.allow_auto_mode);
    assert_eq!(mapped.permission_directories, ["/w"]);
    assert_eq!(mapped.remember_label, None);
    assert_eq!(mapped.plan.as_deref(), Some("the plan"));
    let command = mapped.command.unwrap();
    assert_eq!(command.command, "ls");
    assert_eq!(command.cwd.as_deref(), Some("/w"));
    assert_eq!(command.reason.as_deref(), Some("look"));
    assert_eq!(mapped.exec_policy_amendment, Some(vec!["ls".to_owned()]));
    assert_eq!(mapped.persist_modes, [PersistMode::Always]);
    let agy = mapped.antigravity.unwrap();
    assert_eq!(agy.action_description.as_deref(), Some("act"));
    assert_eq!(agy.always_allow_pattern.as_deref(), Some("pattern"));
    assert_eq!(mapped.file_changes[0].path, "a.rs");
    assert_eq!(mapped.file_changes[0].kind, Some(EditKind::Delete));
    assert_eq!(mapped.file_changes[0].lines_added, Some(1));
    assert_eq!(mapped.file_changes[0].lines_removed, Some(2));
}

#[test]
fn every_value_and_response_maps() {
    for (on_ffi, on_core) in [
        (ElicitationValue::Null, CoreValue::Null),
        (
            ElicitationValue::Bool { value: true },
            CoreValue::Bool(true),
        ),
        (
            ElicitationValue::Integer { value: -7 },
            CoreValue::Integer(-7),
        ),
        (
            ElicitationValue::Number { value: 0.5 },
            CoreValue::Number(0.5),
        ),
        (
            ElicitationValue::Text { value: "t".into() },
            CoreValue::Text("t".into()),
        ),
        (
            ElicitationValue::TextList {
                values: vec!["a".into()],
            },
            CoreValue::TextList(vec!["a".into()]),
        ),
    ] {
        assert_eq!(CoreValue::from(on_ffi), on_core);
    }

    for (on_ffi, on_core) in [
        (DecisionResponse::Approve, core::DecisionResponse::Approve),
        (DecisionResponse::Decline, core::DecisionResponse::Decline),
        (DecisionResponse::Cancel, core::DecisionResponse::Cancel),
        (
            DecisionResponse::Answer { value: "a".into() },
            core::DecisionResponse::Answer("a".into()),
        ),
        (
            DecisionResponse::Form {
                values: HashMap::from([("k".to_owned(), ElicitationValue::Bool { value: false })]),
            },
            core::DecisionResponse::Form(BTreeMap::from([(
                "k".to_owned(),
                CoreValue::Bool(false),
            )])),
        ),
        (
            DecisionResponse::ApproveAllEdits,
            core::DecisionResponse::ApproveAllEdits,
        ),
        (
            DecisionResponse::ApproveAutoMode,
            core::DecisionResponse::ApproveAutoMode,
        ),
        (
            DecisionResponse::ApproveDirectories,
            core::DecisionResponse::ApproveDirectories,
        ),
        (
            DecisionResponse::ApproveRemembering,
            core::DecisionResponse::ApproveRemembering,
        ),
        (
            DecisionResponse::ApproveCommandPolicy {
                policy: vec!["ls".into()],
            },
            core::DecisionResponse::ApproveCommandPolicy(vec!["ls".into()]),
        ),
        (
            DecisionResponse::ApprovePersist {
                mode: PersistMode::Session,
            },
            core::DecisionResponse::ApprovePersist(core::PersistMode::Session),
        ),
        (
            DecisionResponse::DeclineWithFeedback {
                feedback: "no".into(),
            },
            core::DecisionResponse::DeclineWithFeedback("no".into()),
        ),
    ] {
        assert_eq!(core::DecisionResponse::from(on_ffi), on_core);
    }
}

#[test]
fn a_form_with_only_good_values_has_no_problem() {
    let field = core::FormField::new("title", "Title", core::FieldKind::Text);
    assert_eq!(
        validate_form(
            vec![field.into()],
            HashMap::from([(
                "title".to_owned(),
                ElicitationValue::Text { value: "ok".into() },
            )]),
        ),
        None
    );
}
