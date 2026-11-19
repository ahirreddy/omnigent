//! Trigger templates, ported from `web/src/components/scheduled/triggerTemplates.test.ts`.

#![allow(
    clippy::too_many_lines,
    reason = "each prompt's sentences are asserted together, as the web's tests do"
)]

use serde_json::Value;

use super::*;

const JQL: &str = r#"project = "ES" AND labels = "omnigent""#;
const LINK: &str = "https://omni.example.com/c/CONVERSATION_ID";

fn context() -> TriggerPromptContext {
    TriggerPromptContext {
        placement: WorkerPlacement::SameHost,
        session_link: LINK.into(),
        agent_id: None,
        model: None,
        effort: None,
        permission_mode: None,
        polling_interval_minutes: None,
        task_session: false,
        task_session_title: None,
        message_max_chars: None,
    }
}

fn config_context() -> TriggerConfigContext {
    TriggerConfigContext {
        session_link: LINK.into(),
        polling_interval_minutes: None,
        task_session_title: None,
        message_max_chars: None,
    }
}

fn row(field: &str, operator: TriggerOperator, value: &str) -> TriggerCondition {
    TriggerCondition {
        field: field.into(),
        operator,
        value: value.into(),
        name: None,
    }
}

/// A Jira trigger for project ES labeled omnigent, as the web's tests start.
fn fields() -> TriggerFields {
    TriggerFields {
        event: "created".into(),
        scope: "ES".into(),
        scope_operator: None,
        conditions: vec![row("label", Is, "omnigent")],
        target: None,
        instructions: "Investigate the ticket.".into(),
        link_back: true,
        link_back_touched: None,
    }
}

fn config(source: TriggerSource) -> TriggerConfig {
    let mut fields = empty_trigger_fields(source);
    fields.scope = "abc".into();
    fields.instructions = "Do the work.".into();
    TriggerConfig {
        source,
        fields,
        task_session: false,
        worker: TriggerWorker {
            placement: WorkerPlacement::SameHost,
            agent_id: None,
            model: String::new(),
            effort: String::new(),
            permission_mode: String::new(),
        },
    }
}

#[test]
fn every_source_names_its_service_template_and_header_id() {
    assert_eq!(
        TriggerSource::ALL.map(TriggerSource::service_name),
        ["Jira", "Slack", "GitHub", "Linear", "PagerDuty"]
    );
    assert_eq!(
        TriggerSource::ALL.map(TriggerSource::id),
        ["jira", "slack", "github", "linear", "pagerduty"]
    );
    for source in TriggerSource::ALL {
        assert_eq!(TriggerSource::from_id(source.id()), Some(source));
        let template = trigger_template(source);
        assert_eq!(template.source, source);
        assert_ne!(template.events, []);
        assert!(template.tools_example.contains(source.service_name()));
    }
    assert_eq!(trigger_template(TriggerSource::Github).title, "GitHub");
    assert_eq!(
        trigger_template(TriggerSource::PagerDuty).scope_operators,
        [
            TriggerScopeOperator::Is,
            TriggerScopeOperator::In,
            TriggerScopeOperator::Contains
        ]
    );
    for source in [
        TriggerSource::Jira,
        TriggerSource::Slack,
        TriggerSource::Github,
        TriggerSource::Linear,
    ] {
        assert_eq!(
            trigger_template(source).scope_operators,
            [TriggerScopeOperator::Is, TriggerScopeOperator::In]
        );
    }
}

#[test]
fn completeness_needs_scope_values_and_bounded_instructions() {
    let with = |change: fn(&mut TriggerFields)| {
        let mut fields = fields();
        change(&mut fields);
        trigger_fields_complete(TriggerSource::Jira, &fields, MAX_INSTRUCTIONS_CHARS)
    };
    assert!(with(|fields| fields.conditions.clear()));
    assert!(!with(|fields| fields.scope = "  ".into()));
    assert!(!with(|fields| fields.scope = " , ,".into()));
    assert!(!with(|fields| fields.conditions[0].value = " ".into()));
    assert!(with(
        |fields| fields.conditions = vec![row("assignee", Empty, "")]
    ));
    assert!(!with(
        |fields| fields.conditions = vec![row("custom_field", Is, "Backend")]
    ));
    assert!(!with(|fields| fields.instructions.clear()));
    assert!(with(|fields| fields.instructions = "x".repeat(16_000)));
    assert!(!with(|fields| fields.instructions = "x".repeat(16_001)));
    // One value can't be a list.
    assert!(!with(|fields| {
        fields.scope = "ES, OPS".into();
        fields.scope_operator = Some(TriggerScopeOperator::Is);
    }));
    assert!(with(|fields| {
        fields.scope = "ES, OPS".into();
        fields.scope_operator = Some(TriggerScopeOperator::In);
    }));
    // The budget counts UTF-16 units, as the web's `length`.
    let mut emoji = fields();
    emoji.instructions = "\u{1F642}".repeat(1_000);
    assert!(trigger_fields_complete(TriggerSource::Jira, &emoji, 2_000));
    emoji.instructions.push('x');
    assert!(!trigger_fields_complete(TriggerSource::Jira, &emoji, 2_000));
}

#[test]
fn a_review_trigger_needs_a_reviewer_github_can_name() {
    let mut fields = with_trigger_event(TriggerSource::Github, &fields(), "review");
    fields.scope = "acme/app".into();
    assert_eq!(fields.target.as_deref(), Some("me"));
    assert!(!fields.link_back);
    assert!(trigger_fields_complete(
        TriggerSource::Github,
        &fields,
        MAX_INSTRUCTIONS_CHARS
    ));
    for (reviewer, valid) in [
        ("octocat", true),
        ("@octocat", true),
        ("acme/platform-team", true),
        ("", false),
        ("not a login", false),
        ("a/b/c", false),
    ] {
        fields.target = Some(reviewer.into());
        assert_eq!(
            trigger_fields_complete(TriggerSource::Github, &fields, MAX_INSTRUCTIONS_CHARS),
            valid,
            "{reviewer}"
        );
    }
    assert_eq!(
        parse_github_reviewer("acme/platform-team"),
        Some(GithubReviewer::Team("acme".into(), "platform-team".into()))
    );
    assert_eq!(parse_github_reviewer(" ME "), Some(GithubReviewer::Me));
}

#[test]
fn switching_events_clears_what_the_new_event_reads_differently() {
    let mut slack = empty_trigger_fields(TriggerSource::Slack);
    slack.scope = "#eng".into();
    slack.conditions = vec![row("author", Is, "@bot"), row("text", Contains, "error")];
    let dm = with_trigger_event(TriggerSource::Slack, &slack, "dm");
    assert_eq!(dm.scope, "");
    assert_eq!(dm.conditions, vec![row("text", Contains, "error")]);
    let group = with_trigger_event(TriggerSource::Slack, &dm, "group_dm");
    assert_eq!(group.scope_operator, Some(TriggerScopeOperator::In));
    assert_eq!(
        trigger_event_description(TriggerSource::Linear, "created"),
        "Runs your automation on all new issues that match these conditions. Older issues are skipped, even if they are edited to match later."
    );
    assert!(trigger_event_description(TriggerSource::Jira, "assigned").contains("assigned again"));
    assert_eq!(
        strip_scope_prefix("#eng, ##bugs,  #ops", "#"),
        "eng, bugs,  ops"
    );
    assert_eq!(slack_channels("eng, C0123ABCD"), "#eng, C0123ABCD");
    assert_eq!(
        slack_people("alice, @Alice, U0123ABCD, bob@example.com"),
        ["@alice", "U0123ABCD", "bob@example.com"]
    );
}

#[test]
fn splits_a_trailing_order_by_outside_quotes() {
    for (jql, condition, order) in [
        ("project = ES", "project = ES", ""),
        (
            "project = ES ORDER BY created DESC",
            "project = ES",
            "ORDER BY created DESC",
        ),
        (
            r#"summary ~ "order by" order by updated"#,
            r#"summary ~ "order by""#,
            "order by updated",
        ),
        ("project = SHORDER", "project = SHORDER", ""),
    ] {
        assert_eq!(
            split_jql_order_by(jql),
            (condition.to_owned(), order.to_owned()),
            "{jql}"
        );
    }
}

#[test]
fn compiles_jira_rows() {
    let jql = |scope: &str, rows: Vec<TriggerCondition>| {
        compile_jira_jql(&TriggerFields {
            scope: scope.into(),
            conditions: rows,
            ..fields()
        })
    };
    assert_eq!(jql("ES", vec![]), r#"project = "ES""#);
    assert_eq!(jql("ES, OPS", vec![]), r#"project in ("ES", "OPS")"#);
    assert_eq!(
        compile_jira_jql(&TriggerFields {
            scope_operator: Some(TriggerScopeOperator::In),
            conditions: vec![],
            ..fields()
        }),
        r#"project in ("ES")"#
    );
    assert_eq!(
        jql("ES", vec![row("label", IsNot, "wontfix")]),
        r#"project = "ES" AND (labels is EMPTY OR labels != "wontfix")"#
    );
    assert_eq!(
        jql("ES", vec![row("assignee", Is, "me")]),
        r#"project = "ES" AND assignee = currentUser()"#
    );
    assert_eq!(
        jql(
            "ES",
            vec![row(
                "jql",
                Matches,
                r#"summary ~ "crash" OR priority = Highest ORDER BY created DESC"#
            )]
        ),
        r#"project = "ES" AND (summary ~ "crash" OR priority = Highest)"#
    );
    let custom = |name: &str, operator| TriggerCondition {
        name: Some(name.into()),
        ..row("custom_field", operator, "Backend")
    };
    assert_eq!(
        jql("ES", vec![custom("ES Component", Is)]),
        r#"project = "ES" AND "ES Component" = "Backend""#
    );
    assert_eq!(
        jql("ES", vec![custom("\"ES Component\"", IsNot)]),
        r#"project = "ES" AND ("ES Component" is EMPTY OR "ES Component" != "Backend")"#
    );
    assert_eq!(
        jql("ES", vec![custom("cf[10010]", Empty)]),
        r#"project = "ES" AND cf[10010] is EMPTY"#
    );
    let assigned = TriggerFields {
        event: "assigned".into(),
        target: Some("me".into()),
        conditions: vec![],
        ..fields()
    };
    assert_eq!(
        compile_jira_jql(&assigned),
        r#"project = "ES" AND assignee = currentUser()"#
    );
    assert_eq!(
        jira_assignee(Some("unassigned")),
        (
            "assignee CHANGED TO EMPTY".into(),
            "assignee is EMPTY".into()
        )
    );
}

#[test]
fn compiles_github_queries() {
    let query = |event: &str, rows: Vec<TriggerCondition>| {
        compile_github_query(&TriggerFields {
            event: event.into(),
            scope: "acme/app".into(),
            conditions: rows,
            ..fields()
        })
    };
    assert_eq!(query("issue", vec![]), "repo:acme/app is:issue");
    assert_eq!(query("pr", vec![]), "repo:acme/app is:pr");
    assert_eq!(query("any", vec![]), "repo:acme/app");
    assert_eq!(
        query(
            "issue",
            vec![
                row("label", Is, "good first issue"),
                row("label", IsNot, "wontfix"),
                row("author", IsNot, "@dependabot"),
                row("qualifiers", Matches, "no:assignee"),
            ]
        ),
        r#"repo:acme/app is:issue label:"good first issue" -label:wontfix -author:dependabot no:assignee"#
    );
    assert_eq!(
        query("pr", vec![row("reviewer", IsNot, "acme/core")]),
        "repo:acme/app is:pr -team-review-requested:acme/core"
    );
    let review = TriggerFields {
        event: "review".into(),
        scope: "acme/app".into(),
        target: Some("me".into()),
        conditions: vec![],
        ..fields()
    };
    assert_eq!(
        compile_github_query(&review),
        "repo:acme/app is:pr is:open -is:draft user-review-requested:@me"
    );
}

#[test]
fn describes_linear_and_pagerduty_rows_as_the_web() {
    let linear = |rows: Vec<TriggerCondition>| {
        describe_linear_filter(&TriggerFields {
            scope: "ENG".into(),
            conditions: rows,
            ..fields()
        })
    };
    assert_eq!(linear(vec![]), "");
    assert_eq!(
        linear(vec![
            row("label", Is, "Bug"),
            row("status", IsNot, "Done"),
            row("priority", Is, "Urgent"),
            row("project", IsNot, "Mobile app"),
            row("creator", Is, "Me"),
            row("text", NotContains, "flaky"),
        ]),
        r#"that have label "Bug", don't have status "Done", have priority "Urgent", aren't in project "Mobile app", were created by you and don't have "flaky" in the title or description"#
    );
    assert_eq!(
        linear(vec![row("assignee", Is, "me")]),
        "that are assigned to you"
    );
    assert_eq!(
        linear(vec![row("assignee", IsNot, "ana@example.com")]),
        r#"that aren't assigned to "ana@example.com""#
    );
    assert_eq!(
        linear(vec![row("assignee", Empty, "")]),
        "that are unassigned"
    );
    assert_eq!(
        linear(vec![row("assignee", NotEmpty, "")]),
        "that are assigned to someone"
    );
    let pagerduty = |rows: Vec<TriggerCondition>| {
        describe_pagerduty_filter(&TriggerFields {
            scope: "Checkout API".into(),
            conditions: rows,
            ..fields()
        })
    };
    assert_eq!(pagerduty(vec![]), "");
    assert_eq!(
        pagerduty(vec![
            row("urgency", Is, "high"),
            row("priority", IsNot, "P5"),
            row("status", IsNot, "resolved"),
            row("assignee", Is, "Me"),
            row("title", Contains, "database"),
        ]),
        r#"that have urgency "high", don't have priority "P5", don't have status "resolved", are assigned to you and have "database" in the title"#
    );
    assert_eq!(
        pagerduty(vec![
            row("assignee", IsNot, "ana@example.com"),
            row("title", NotContains, "test"),
        ]),
        r#"that aren't assigned to "ana@example.com" and don't have "test" in the title"#
    );
}

fn assert_contains(prompt: &str, expected: &[&str]) {
    for text in expected {
        assert!(prompt.contains(text), "missing {text:?} in:\n{prompt}");
    }
}

#[test]
fn renders_the_jira_manager_prompt_like_the_web() {
    let prompt = render_trigger_prompt(TriggerSource::Jira, &fields(), &context());
    assert!(prompt.starts_with(
        "This automation watches Jira and starts one Omnigent session for each newly created ticket that matches. Every run sends this prompt to this same session.\n\nWatch: new Jira tickets matching this JQL:\n"
    ));
    assert_contains(
        &prompt,
        &[
            JQL,
            "1. If your tools load on demand, load every tool this run needs in one tool search before your first call, naming them all: your Jira tools and each sys_session tool the steps below use, and sys_session_get_info, which returns your session and agent IDs. Read your state",
            "On the first run, use one hour ago and nothing pending.",
            "Note the current UTC time: the \"Run time:\" line near the end of this message gives it, so don't check the clock unless that line is missing.",
            "call sys_session_create with agent_id set to your agent ID, placement \"same_host\", title \"Jira <ticket key>\", and a message under 32000 characters.",
            "Comment \"Omnigent session: https://omni.example.com/c/CONVERSATION_ID\" on each ticket you started a session for.",
            "Instructions for each session:\nInvestigate the ticket.\nAnything you post for this",
            "If the last message you wrote before this run's message is a reply with no \"Delivery pending:\" entries",
        ],
    );
    assert!(!prompt.contains("CHANGED"));
    assert!(!prompt.contains("Watching since:"));
    let slow = render_trigger_prompt(
        TriggerSource::Jira,
        &fields(),
        &TriggerPromptContext {
            polling_interval_minutes: Some(240),
            message_max_chars: Some(LEGACY_SESSION_MESSAGE_MAX_CHARS),
            model: Some("opus".into()),
            effort: Some("high".into()),
            placement: WorkerPlacement::Managed,
            ..context()
        },
    );
    assert_contains(
        &slow,
        &[
            "On the first run, use 240 minutes ago and nothing pending.",
            "placement \"managed\", title \"Jira <ticket key>\", model \"opus\", reasoning_effort \"high\", and a message under 8000 characters.",
        ],
    );
    assert!(!slow.contains("make its own git worktree"));
}

#[test]
fn renders_the_linear_search_reading_every_newest_first_page() {
    let prompt = render_trigger_prompt(
        TriggerSource::Linear,
        &TriggerFields {
            event: "created".into(),
            scope: "ENG, OPS".into(),
            conditions: vec![row("label", Is, "Bug")],
            instructions: "Investigate the issue.".into(),
            ..fields()
        },
        &context(),
    );
    assert_contains(
        &prompt,
        &[
            "This automation watches Linear and starts one Omnigent session for each newly created issue that matches.",
            r#"Watch: new Linear issues in teams ENG, OPS that have label "Bug""#,
            r#"Use your Linear tools to list the issues created in teams ENG, OPS since that time, for example list_issues with team set to each team in turn, createdAt set to that time in ISO 8601 and orderBy "createdAt". Only issues that have label "Bug" count."#,
            "The tool lists newest first: follow the cursor while hasNextPage is true until you have read every page, then work through the results oldest first. If you can't read every page, start no sessions in this run and keep the previous check time.",
            r#"title "Linear <issue identifier>""#,
            "gives the issue's identifier, link, title and description between <linear-issue> and </linear-issue> lines.",
            r#"Comment "Omnigent session: https://omni.example.com/c/CONVERSATION_ID" on each issue you started a session for."#,
            "say that this automation needs a Linear MCP server where it runs.",
        ],
    );
    assert!(!prompt.contains("stop at the last result you read"));
    let unfiltered = render_trigger_prompt(
        TriggerSource::Linear,
        &TriggerFields {
            scope: "ENG".into(),
            conditions: vec![],
            ..fields()
        },
        &context(),
    );
    assert_contains(
        &unfiltered,
        &[
            "Watch: new Linear issues in team ENG\n",
            "with team set to that team,",
            "Every issue counts.",
        ],
    );
}

#[test]
fn renders_the_pagerduty_search_across_statuses() {
    let prompt = render_trigger_prompt(
        TriggerSource::PagerDuty,
        &TriggerFields {
            event: "triggered".into(),
            scope: "Checkout API, Payments".into(),
            conditions: vec![row("urgency", Is, "high")],
            instructions: "Investigate the incident.".into(),
            ..fields()
        },
        &context(),
    );
    assert_contains(
        &prompt,
        &[
            "This automation watches PagerDuty and starts one Omnigent session for each newly created incident that matches.",
            r#"Watch: new PagerDuty incidents on services Checkout API, Payments that have urgency "high""#,
            "Use your PagerDuty tools to find each of those services by name or ID. A name that matches no service or more than one counts as no match: say so in your reply.",
            r#"Then list the incidents created on them since that time, in any status and not only the ones assigned to you, for example GET /incidents with service_ids[] set to their IDs, since set to that time in ISO 8601 and sort_by "created_at:asc". Only incidents that have urgency "high" count."#,
            "Read every page of results, following the offset while more is true, then work through them oldest first. If you can't read every page, start no sessions in this run and keep the previous check time.",
            r#"title "PagerDuty #<incident number>""#,
            "gives the incident's number, link, title, service, urgency, priority and description between <pagerduty-incident> and </pagerduty-incident> lines.",
            r#"Add a note "Omnigent session: https://omni.example.com/c/CONVERSATION_ID" to each incident you started a session for."#,
            "say that this automation needs a PagerDuty MCP server where it runs.",
        ],
    );
    let one = render_trigger_prompt(
        TriggerSource::PagerDuty,
        &TriggerFields {
            event: "triggered".into(),
            scope: "Checkout API".into(),
            conditions: vec![],
            ..fields()
        },
        &context(),
    );
    assert_contains(
        &one,
        &[
            "Watch: new PagerDuty incidents on service Checkout API\n",
            "find that service by name or ID.",
            "service_ids[] set to its ID,",
            "Every incident counts.",
        ],
    );
    let contains = render_trigger_prompt(
        TriggerSource::PagerDuty,
        &TriggerFields {
            event: "triggered".into(),
            scope: " payments ".into(),
            scope_operator: Some(TriggerScopeOperator::Contains),
            conditions: vec![],
            ..fields()
        },
        &context(),
    );
    assert_contains(
        &contains,
        &[
            "Watch: new PagerDuty incidents on services whose name contains \"payments\"\n",
            "Use your PagerDuty tools to find every service whose name contains \"payments\", ignoring case, for example GET /services with query set to \"payments\", reading every page and keeping only names that contain it. If none does, say so in your reply and list no incidents, since an incident list without service IDs covers every service. Then list the incidents created on them since that time, in any status and not only the ones assigned to you, for example GET /incidents with service_ids[] set to their IDs,",
        ],
    );
    assert!(!contains.contains("by name or ID"));
}

#[test]
fn renders_github_and_slack_worker_posting_rules() {
    let github = render_trigger_prompt(
        TriggerSource::Github,
        &TriggerFields {
            event: "issue".into(),
            scope: "acme/app".into(),
            conditions: vec![row("label", Is, "won't fix")],
            ..fields()
        },
        &context(),
    );
    assert_contains(
        &github,
        &[
            "-f q='repo:acme/app is:issue label:\"won'\\''t fix\" created:>=<that time>' -f sort=created",
            "1. If your tools load on demand, load every tool this run needs in one tool search before your first call, naming them all: your GitHub tools and each sys_session tool the steps below use, and sys_session_get_info, which returns your session and agent IDs. Before using GitHub.com, verify which authenticated account",
            "\n\nPosting instructions for each session:\nAnything you post for this",
        ],
    );
    let mut slack_fields = empty_trigger_fields(TriggerSource::Slack);
    slack_fields.scope = "#eng-support".into();
    slack_fields.instructions = "Answer it.".into();
    let slack = render_trigger_prompt(TriggerSource::Slack, &slack_fields, &context());
    assert_contains(
        &slack,
        &[
            "Watch: new Slack messages in #eng-support\n",
            "jq -c '.result | fromjson | (.channels[] | select(.name == \"eng-support\") | {id, name}), .response_metadata.next_cursor' <file>",
            "Track progress: <https://omni.example.com/c/CONVERSATION_ID|Omni Session>",
            "Above it, write a \"Slack IDs:\" line",
        ],
    );
    // A Slack worker posts its own link, so the manager doesn't.
    assert!(!slack.contains("Link-back pending:"));
}

#[test]
fn renders_one_task_session_for_every_match() {
    let prompt = render_trigger_prompt(
        TriggerSource::Jira,
        &fields(),
        &TriggerPromptContext {
            task_session: true,
            task_session_title: Some("  Triage  ".into()),
            ..context()
        },
    );
    assert!(prompt.starts_with(
        "This automation watches Jira and starts one Omnigent session, its task session, and sends it each newly created ticket that matches."
    ));
    assert_contains(
        &prompt,
        &[
            "title \"Triage\"",
            "Instructions for the task session:\nInvestigate the ticket.",
            "sys_session_get_history (tail_items 50)",
        ],
    );
    assert!(is_task_session_trigger_prompt(&prompt));
    assert!(is_trigger_prompt(&prompt));
}

#[test]
fn a_header_round_trips_the_form() {
    for source in TriggerSource::ALL {
        let saved = encode_trigger_prompt(&config(source), &config_context());
        assert!(
            saved.starts_with("<!-- omnigent-trigger v1 {\"source\":"),
            "{saved}"
        );
        assert_eq!(decode_trigger_prompt(&saved), Some(config(source)));
        assert!(is_trigger_prompt(&saved));
        assert_eq!(trigger_prompt_source(&saved), Some(source));
        assert_eq!(
            strip_trigger_header(&saved),
            render_trigger_config_prompt(&config(source), &config_context())
        );
    }
    let mut rich = config(TriggerSource::Jira);
    rich.fields.conditions = vec![TriggerCondition {
        name: Some("ES Component".into()),
        ..row("custom_field", IsNot, "<-->")
    }];
    rich.fields.target = Some("me".into());
    rich.fields.event = "assigned".into();
    rich.fields.link_back_touched = Some(true);
    rich.task_session = true;
    rich.worker = TriggerWorker {
        placement: WorkerPlacement::Managed,
        agent_id: Some("ag_claude".into()),
        model: "opus".into(),
        effort: "high".into(),
        permission_mode: "acceptEdits".into(),
    };
    let saved = encode_trigger_prompt(&rich, &config_context());
    let header = saved.lines().next().unwrap_or_default();
    // A value such as "-->" can't end the comment early.
    assert!(header.contains("\\u003c--\\u003e"));
    assert!(!header.contains("<-->"));
    assert_eq!(decode_trigger_prompt(&saved), Some(rich));
    let mut older = config(TriggerSource::Jira);
    older.fields.scope_operator = None;
    assert_eq!(
        decode_trigger_prompt(&encode_trigger_prompt(&older, &config_context())),
        Some(older)
    );
}

#[test]
fn the_canonical_header_is_the_webs() {
    let mut config = config(TriggerSource::Slack);
    config.fields.conditions = vec![row("text", Contains, "say \"hi\"\n")];
    assert_eq!(
        canonical_config(&config),
        r#"{"source":"slack","event":"posted","scope":"abc","scopeOperator":"is","conditions":[{"field":"text","operator":"contains","value":"say \"hi\"\n"}],"instructions":"Do the work.","linkBack":true,"worker":{"placement":"same_host","agentId":null,"model":"","effort":""}}"#
    );
}

#[test]
fn a_header_edited_outside_the_form_opens_as_free_text() {
    let saved = encode_trigger_prompt(&config(TriggerSource::Jira), &config_context());
    for edited in [
        strip_trigger_header(&saved).to_owned(),
        saved.replace("omnigent-trigger v1", "omnigent-trigger v2"),
        saved.replace("{\"source\"", "{source\""),
        saved.replace("\"source\":\"jira\"", "\"source\":\"zendesk\""),
        saved.replace("\"event\":\"created\"", "\"event\":\"edited\""),
        saved.replace("\"scope\":\"abc\"", "\"scope\":\"xyz\""),
        saved.replace(
            "Instructions for each session:\nDo the work.",
            "Instructions for each session:\nDo nothing.",
        ),
        format!("Note\n{saved}"),
    ] {
        assert_eq!(decode_trigger_prompt(&edited), None, "{edited}");
    }
    let unsigned = saved.replace(
        &format!(
            ",\"fingerprint\":\"{}\"",
            trigger_fingerprint(&config(TriggerSource::Jira), strip_trigger_header(&saved))
        ),
        "",
    );
    assert_eq!(decode_trigger_prompt(&unsigned), None);
    assert!(has_trigger_header(&unsigned));
    let prompt = "Summarize.\n<!-- omnigent-trigger v1 {} -->\n";
    assert_eq!(strip_trigger_header(prompt), prompt);
    assert!(!has_trigger_header("<!-- omnigent-trigger v1 -->\nBody"));
}

#[test]
fn an_older_trigger_splits_into_its_instructions() {
    let prompt = render_trigger_prompt(TriggerSource::Jira, &fields(), &context());
    let parts = split_trigger_prompt(&prompt);
    assert_eq!(parts.user_prompt, "Investigate the ticket.");
    let system = parts.system_prompt.clone().unwrap_or_default();
    assert!(system.ends_with(&format!(
        "\n\nPosting instructions for each session:\n{POSTING_INSTRUCTIONS}"
    )));
    assert_eq!(
        combine_trigger_prompt(&parts.user_prompt, parts.system_prompt.as_deref()),
        prompt
    );
    let edited = combine_trigger_prompt("Fix it.", parts.system_prompt.as_deref());
    assert!(edited.contains("Instructions for each session:\nFix it.\nAnything you post"));
    let github = render_trigger_prompt(
        TriggerSource::Github,
        &TriggerFields {
            event: "issue".into(),
            scope: "acme/app".into(),
            ..fields()
        },
        &context(),
    );
    let parts = split_trigger_prompt(&github);
    assert_eq!(parts.user_prompt, "Investigate the ticket.");
    assert_eq!(
        combine_trigger_prompt(&parts.user_prompt, parts.system_prompt.as_deref()),
        github
    );
    for free in [
        "Summarize the day.",
        "This automation watches Jira but nothing else.",
    ] {
        assert_eq!(split_trigger_prompt(free).system_prompt, None, "{free}");
    }
    assert_eq!(read_trigger_message_max_chars(&prompt), Some(32_000));
}

#[test]
fn the_page_shows_a_triggers_instructions_alone() {
    let saved = encode_trigger_prompt(&config(TriggerSource::Linear), &config_context());
    assert_eq!(
        trigger_prompt_display(&saved, true),
        TriggerPromptDisplay {
            text: "Do the work.".into(),
            instructions_only: true,
        }
    );
    let legacy = render_trigger_prompt(TriggerSource::Jira, &fields(), &context());
    assert_eq!(
        trigger_prompt_display(&legacy, true).text,
        "Investigate the ticket."
    );
    // A header edited outside the form shows the prompt the model runs, without the header.
    let stale = saved.replace("Do the work.", "Do other work.");
    let shown = trigger_prompt_display(&stale, true);
    assert!(!shown.instructions_only);
    assert!(!shown.text.contains("omnigent-trigger"));
    assert_eq!(
        trigger_prompt_display("Summarize.", false),
        TriggerPromptDisplay {
            text: "Summarize.".into(),
            instructions_only: false,
        }
    );
}

#[test]
fn the_message_budget_needs_the_server_and_the_host() {
    let host = |long_messages| TriggerPollingTarget::Host {
        name: "laptop".into(),
        long_messages,
    };
    let full = trigger_message_budget(32_000, &host(true), None);
    assert_eq!(
        (full.message_max_chars, full.instructions_max_chars),
        (32_000, 16_000)
    );
    assert_eq!(full.upgrade_hint, None);
    let old_server = trigger_message_budget(0, &host(true), None);
    assert_eq!(
        (
            old_server.message_max_chars,
            old_server.instructions_max_chars
        ),
        (8_000, 2_000)
    );
    assert_eq!(
        old_server.upgrade_hint.as_deref(),
        Some("Update the Omnigent server to allow up to 16,000.")
    );
    assert_eq!(
        trigger_message_budget(32_000, &host(false), None)
            .upgrade_hint
            .as_deref(),
        Some("Update Omnigent on \"laptop\" and keep it online to allow up to 16,000.")
    );
    assert_eq!(
        trigger_message_budget(32_000, &TriggerPollingTarget::ManagedSandbox, None)
            .upgrade_hint
            .as_deref(),
        Some("Run it on a host with the current Omnigent to allow up to 16,000.")
    );
    assert_eq!(
        trigger_message_budget(32_000, &TriggerPollingTarget::Unknown, None)
            .upgrade_hint
            .as_deref(),
        Some("Pick a host with the current Omnigent to allow up to 16,000.")
    );
    // A trigger saved with the full budget keeps it while its host is unreachable.
    assert_eq!(
        trigger_message_budget(32_000, &host(false), Some(32_000)).upgrade_hint,
        None
    );
}

/// Prompts and headers rendered by main's own `triggerTemplates.ts`.
const MAIN_PROMPTS: &str = include_str!("../../../fixtures/automations/main-trigger-prompts.json");

#[test]
fn renders_and_encodes_byte_for_byte_as_the_web() {
    let cases: Value = serde_json::from_str(MAIN_PROMPTS).unwrap_or_default();
    let cases = cases.as_array().cloned().unwrap_or_default();
    assert_eq!(cases.len(), 14);
    for case in &cases {
        let name = case["name"].as_str().unwrap_or_default();
        let config = case["config"]
            .as_object()
            .and_then(|raw| decode_config(raw).ok());
        assert!(config.is_some(), "{name}: the web's config doesn't decode");
        let Some(config) = config else { continue };
        let ctx = &case["ctx"];
        let number = |key: &str| {
            ctx[key]
                .as_u64()
                .and_then(|value| u32::try_from(value).ok())
        };
        let context = TriggerConfigContext {
            session_link: ctx["sessionLink"].as_str().unwrap_or_default().to_owned(),
            polling_interval_minutes: number("pollingIntervalMinutes"),
            task_session_title: ctx["taskSessionTitle"].as_str().map(str::to_owned),
            message_max_chars: number("messageMaxChars"),
        };
        let encoded = case["encoded"].as_str().unwrap_or_default();
        let body = render_trigger_config_prompt(&config, &context);
        assert_eq!(body, strip_trigger_header(encoded), "{name}: body");
        assert_eq!(
            encode_trigger_prompt(&config, &context),
            encoded,
            "{name}: header"
        );
        assert_eq!(
            decode_trigger_prompt(encoded),
            Some(config),
            "{name}: decode"
        );
        assert_eq!(
            is_task_session_trigger_prompt(&body),
            case["taskSession"].as_bool().unwrap_or_default(),
            "{name}: task session"
        );
        let split = split_trigger_prompt(&body);
        assert_eq!(
            split.system_prompt.map(|_| split.user_prompt),
            case["splitUserPrompt"].as_str().map(str::to_owned),
            "{name}: split"
        );
    }
}

#[test]
fn the_fingerprint_is_the_published_cyrb53() {
    // bryc's published cyrb53 vectors (7929297801672961 for "a"), and UTF-16 units beyond
    // the BMP.
    assert_eq!(cyrb53("a"), "1c2ba782c97901");
    assert_eq!(cyrb53("b"), "1eda5bc254d2bf");
    assert_eq!(cyrb53("revenge"), "0e64cc3b748385");
    assert_eq!(cyrb53("revenue"), "1d85148d13f93a");
    assert_eq!(cyrb53(""), "0bdcb81aee8d83");
    assert_eq!(cyrb53("\u{e9}\u{1F642} mixed\n"), "014c80285df9dd");
}

#[test]
fn every_operator_has_a_generic_label_and_header_id() {
    for operator in TriggerOperator::ALL {
        assert_eq!(TriggerOperator::from_id(operator.id()), Some(operator));
        assert_ne!(operator.label(), "");
    }
    let assignee = &trigger_template(TriggerSource::Jira).fields[4];
    assert_eq!(assignee.operator_label(Empty), "is unassigned");
    assert_eq!(assignee.operator_label(Is), "equals");
    assert_eq!(
        trigger_condition_fields(TriggerSource::Github, "review")
            .iter()
            .map(|field| field.id)
            .collect::<Vec<_>>(),
        ["label", "author", "qualifiers"]
    );
}
