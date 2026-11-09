//! Trigger templates, ported from `web/src/components/scheduled/triggerTemplates.test.ts`.

use super::*;

const JQL: &str = r#"project = "ES" AND labels = "omnigent""#;

fn context() -> TriggerPromptContext {
    TriggerPromptContext {
        placement: WorkerPlacement::SameHost,
        session_link: "https://omni.example.com/c/CONVERSATION_ID".into(),
        model: None,
        effort: None,
    }
}

fn row(field: &str, operator: TriggerOperator, value: &str) -> TriggerCondition {
    TriggerCondition {
        field: field.into(),
        operator,
        value: value.into(),
    }
}

/// A Jira trigger for project ES labeled omnigent.
fn fields() -> TriggerFields {
    TriggerFields {
        event: "created".into(),
        scope: "ES".into(),
        conditions: vec![row("label", Is, "omnigent")],
        instructions: "Investigate the ticket.".into(),
        link_back: true,
    }
}

#[test]
fn completeness_needs_scope_values_and_bounded_instructions() {
    let with = |change: fn(&mut TriggerFields)| {
        let mut fields = fields();
        change(&mut fields);
        trigger_fields_complete(&fields)
    };
    assert!(with(|fields| fields.conditions.clear()));
    assert!(!with(|fields| fields.scope = "  ".into()));
    assert!(!with(|fields| fields.scope = " , ,".into()));
    assert!(!with(|fields| fields.conditions[0].value = " ".into()));
    assert!(with(
        |fields| fields.conditions = vec![row("assignee", Empty, "")]
    ));
    assert!(!with(|fields| fields.instructions.clear()));
    assert!(with(
        |fields| fields.instructions = "x".repeat(MAX_INSTRUCTIONS_CHARS)
    ));
    assert!(!with(
        |fields| fields.instructions = "x".repeat(MAX_INSTRUCTIONS_CHARS + 1)
    ));
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
        jql("ES", vec![row("label", IsNot, "wontfix")]),
        r#"project = "ES" AND (labels is EMPTY OR labels != "wontfix")"#
    );
    assert_eq!(
        jql("ES", vec![row("assignee", Is, "me")]),
        r#"project = "ES" AND assignee = currentUser()"#
    );
    assert_eq!(
        jql("ES", vec![row("assignee", NotEmpty, "")]),
        r#"project = "ES" AND assignee is not EMPTY"#
    );
    assert_eq!(
        jql("ES", vec![row("label", Is, r#"say "hi""#)]),
        r#"project = "ES" AND labels = "say \"hi\"""#
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
        query("issue", vec![row("assignee", Is, "me")]),
        "repo:acme/app is:issue assignee:@me"
    );
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
}

#[test]
fn describes_slack_rows_as_one_clause() {
    let filter = |rows: Vec<TriggerCondition>| {
        describe_slack_filter(&TriggerFields {
            conditions: rows,
            ..fields()
        })
    };
    assert_eq!(filter(vec![]), "");
    assert_eq!(
        filter(vec![
            row("text", NotContains, "resolved"),
            row("topic", About, "a production outage"),
            row("author", IsNot, "@alerts-bot"),
        ]),
        r#"whose text doesn't contain "resolved", that are about a production outage and not posted by @alerts-bot"#
    );
}

#[test]
fn renders_the_manager_prompt_like_the_web() {
    let prompt = render_trigger_prompt(TriggerSource::Jira, &fields(), &context());
    for expected in [
        "starts one Omnigent session for each newly created ticket that matches.".to_owned(),
        format!("Watch: new Jira tickets matching this JQL:\n{JQL}"),
        r#"placement "same_host""#.to_owned(),
        r#"title "Jira <ticket key>""#.to_owned(),
        "then gives the ticket's key, link, title and description between <jira-ticket> and </jira-ticket> lines.".to_owned(),
        "These sessions share your workspace".to_owned(),
        r#"Comment "Omnigent session: https://omni.example.com/c/CONVERSATION_ID" on each ticket"#.to_owned(),
        "Replace CONVERSATION_ID with the conversation_id that sys_session_create returned".to_owned(),
        format!("search for ({JQL}) AND created >= <that time> ORDER BY created ASC."),
        "say that this automation needs a Jira MCP server where it runs.".to_owned(),
        "Instructions for each session:\nInvestigate the ticket.\n".to_owned(),
        "\n1. Read your state".to_owned(),
    ] {
        assert!(prompt.contains(&expected), "missing {expected:?}");
    }
    assert!(prompt.ends_with("since it posts with the owner's account."));

    let no_link = render_trigger_prompt(
        TriggerSource::Jira,
        &TriggerFields {
            link_back: false,
            ..fields()
        },
        &TriggerPromptContext {
            placement: WorkerPlacement::Managed,
            model: Some("opus".into()),
            effort: Some("high".into()),
            ..context()
        },
    );
    assert!(!no_link.contains("End each one with a line"));
    assert!(!no_link.contains("share your workspace"));
    assert!(no_link.contains(
        r#"placement "managed", title "Jira <ticket key>", model "opus", reasoning_effort "high""#
    ));

    let github = TriggerFields {
        event: "issue".into(),
        scope: "acme/app".into(),
        conditions: vec![],
        ..fields()
    };
    assert!(
        render_trigger_prompt(TriggerSource::Github, &github, &context())
            .contains("needs the GitHub CLI or a GitHub MCP server where it runs.")
    );
}

#[test]
fn templates_label_their_operators() {
    let assignee = &trigger_template(TriggerSource::Jira).fields[4];
    assert_eq!(assignee.operator_label(Empty), "is unassigned");
    assert_eq!(assignee.operator_label(IsNot), "doesn't equal");
    assert_eq!(empty_trigger_fields(TriggerSource::Github).event, "issue");
}

#[test]
fn every_source_names_its_service_and_template() {
    for (source, service) in [
        (TriggerSource::Jira, "Jira"),
        (TriggerSource::Slack, "Slack"),
        (TriggerSource::Github, "GitHub"),
    ] {
        assert_eq!(source.service_name(), service);
        assert_eq!(trigger_template(source).source, source);
    }
}

#[test]
fn every_operator_has_a_generic_label() {
    let labels = [
        (Is, "equals"),
        (IsNot, "doesn't equal"),
        (Contains, "contains"),
        (NotContains, "doesn't contain"),
        (About, "is about"),
        (Matches, "matches"),
        (Empty, "is empty"),
        (NotEmpty, "is set"),
    ];
    for (operator, label) in labels {
        assert_eq!(operator.label(), label);
    }
}

#[test]
fn a_quoted_order_by_with_an_escaped_quote_stays_in_the_condition() {
    assert_eq!(
        split_jql_order_by(r#"summary ~ "a\" ORDER BY x" ORDER BY created"#),
        (
            r#"summary ~ "a\" ORDER BY x""#.to_owned(),
            "ORDER BY created".to_owned()
        )
    );
    assert_eq!(
        split_jql_order_by("summary ~ 'unterminated ORDER BY x"),
        (
            "summary ~ 'unterminated ORDER BY x".to_owned(),
            String::new()
        )
    );
    assert_eq!(
        split_jql_order_by("\u{1F600} = 1 orderbyte"),
        ("\u{1F600} = 1 orderbyte".to_owned(), String::new())
    );
}

#[test]
fn jira_rows_compile_for_every_field_and_ignore_unknown_ones() {
    let with = |conditions| TriggerFields {
        conditions,
        ..fields()
    };
    assert_eq!(
        compile_jira_jql(&with(vec![
            row("component", Is, "api"),
            row("issuetype", Is, "Bug"),
            row("priority", IsNot, "Low"),
            row("assignee", Empty, ""),
            row("assignee", IsNot, "pat"),
            row("somefield", Is, "ignored"),
        ])),
        r#"project = "ES" AND component = "api" AND issuetype = "Bug" AND priority != "Low" AND assignee is EMPTY AND (assignee is EMPTY OR assignee != "pat")"#
    );
    assert_eq!(
        compile_jira_jql(&with(vec![row("label", Is, r#"a"b\c"#)])),
        r#"project = "ES" AND labels = "a\"b\\c""#,
        "quotes and backslashes cannot end the JQL string"
    );
}

#[test]
fn github_rows_compile_for_every_assignee_shape() {
    let with = |conditions| TriggerFields {
        event: "pr".into(),
        scope: "org/repo".into(),
        conditions,
        instructions: "x".into(),
        link_back: false,
    };
    assert_eq!(
        compile_github_query(&with(vec![
            row("assignee", Is, "@pat"),
            row("assignee", Empty, ""),
            row("mystery", Is, "x"),
        ])),
        "repo:org/repo is:pr assignee:pat no:assignee"
    );
}

#[test]
fn a_slack_prompt_describes_its_channels_and_filter() {
    let slack = |conditions| TriggerFields {
        event: "message".into(),
        scope: "#ops, #eng".into(),
        conditions,
        instructions: "Look into it.".into(),
        link_back: true,
    };
    let everything = render_trigger_prompt(TriggerSource::Slack, &slack(Vec::new()), &context());
    assert!(
        everything.contains("Watch: new Slack messages in #ops, #eng\n"),
        "{everything}"
    );
    assert!(everything.contains("Every top-level message counts."));
    assert!(everything.contains("in the thread of each message"));

    let filtered = render_trigger_prompt(
        TriggerSource::Slack,
        &slack(vec![row("author", Is, "pat")]),
        &context(),
    );
    assert!(
        filtered.contains("in #ops, #eng posted by pat"),
        "{filtered}"
    );
    assert!(filtered.contains("Only messages posted by pat count."));
}

#[test]
fn a_github_prompt_names_the_item_for_its_event() {
    let github = |event: &str| TriggerFields {
        event: event.into(),
        scope: "org/repo".into(),
        conditions: Vec::new(),
        instructions: "Look into it.".into(),
        link_back: false,
    };
    let prompt =
        |event: &str| render_trigger_prompt(TriggerSource::Github, &github(event), &context());
    assert!(prompt("issue").contains("each newly created issue that"));
    assert!(prompt("pr").contains("each newly created pull request that"));
    assert!(prompt("anything").contains("each newly created issue or pull request that"));
}

#[test]
fn hostile_trigger_text_stays_inside_its_quotes() {
    let hostile = TriggerFields {
        event: "issue".into(),
        scope: "org/repo".into(),
        conditions: vec![row("label", Is, "x' ; rm -rf / #")],
        instructions: "Go.".into(),
        link_back: false,
    };
    let prompt = render_trigger_prompt(TriggerSource::Github, &hostile, &context());
    assert!(
        prompt.contains(r"'\''"),
        "single quotes are escaped for the shell: {prompt}"
    );
}
