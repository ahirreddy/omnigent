// Tests for the custom agent bundle and configuration edits; the web's lib/agentBundle.test.ts
// and CreateAgentDialog.test.tsx cover the same rules.
use serde_json::json;

use super::*;

fn draft() -> AgentDraft {
    AgentDraft {
        name: " reviewer ".into(),
        description: "Reviews: PRs".into(),
        instructions: "Be terse.".into(),
        harness: "claude-sdk".into(),
        model: "claude-sonnet-4".into(),
        mcp_servers: vec![
            McpServerDraft::Stdio {
                name: "fs".into(),
                command: "npx".into(),
                args: vec!["-y".into(), "@mcp/fs".into()],
                env: key_value_lines("ROOT=/tmp\n\n"),
            },
            McpServerDraft::Http {
                name: String::new(),
                url: "https://ignored".into(),
                headers: BTreeMap::new(),
            },
        ],
    }
}

/// Reads the stored deflate blocks back (what any gunzip does for them).
fn gunzip_stored(data: &[u8]) -> Vec<u8> {
    assert_eq!(&data[..3], &[0x1f, 0x8b, 8]);
    let mut position = 10;
    let mut output = Vec::new();
    loop {
        let last = data[position] & 1 == 1;
        let length = usize::from(u16::from_le_bytes([data[position + 1], data[position + 2]]));
        let inverse = u16::from_le_bytes([data[position + 3], data[position + 4]]);
        assert_eq!(!inverse, u16::try_from(length).unwrap());
        output.extend_from_slice(&data[position + 5..position + 5 + length]);
        position += 5 + length;
        if last {
            break;
        }
    }
    assert_eq!(
        u32::from_le_bytes(data[position..position + 4].try_into().unwrap()),
        crc32(&output)
    );
    output
}

#[test]
fn crc32_matches_the_check_value() {
    assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
}

#[test]
fn names_follow_the_server_rule() {
    assert!(is_agent_name("my_agent-2"));
    assert!(!is_agent_name("my agent") && !is_agent_name("") && !is_agent_name("a/b"));
    let mut invalid = draft();
    invalid.name = "bad name".into();
    assert!(invalid.problem().is_some());
    invalid.name = "ok".into();
    invalid.model = " ".into();
    assert_eq!(invalid.problem().as_deref(), Some("Enter a model."));
    assert_eq!(draft().problem(), None);
}

#[test]
fn config_yaml_matches_the_web_bundle() {
    let yaml = draft().config_yaml();
    assert_eq!(
        yaml,
        "spec_version: 1\n\nname: reviewer\ndescription: \"Reviews: PRs\"\n\nexecutor:\n  \
         type: omnigent\n  model: claude-sonnet-4\n  config:\n    harness: claude-sdk\n\n\
         tools:\n  builtins:\n    - web_search\n    - web_fetch\n  fs:\n    type: mcp\n    \
         command: npx\n    args: [-y, \"@mcp/fs\"]\n    env:\n      ROOT: /tmp\n\n\
         instructions: AGENTS.md\n"
    );
}

#[test]
fn bundle_is_a_tar_gz_of_config_and_instructions() {
    let archive = gunzip_stored(&draft().bundle());
    assert_eq!(archive.len() % 512, 0);
    assert_eq!(&archive[..11], b"config.yaml");
    assert_eq!(&archive[257..262], b"ustar");
    let size = usize::from_str_radix(std::str::from_utf8(&archive[124..135]).unwrap(), 8).unwrap();
    assert_eq!(&archive[512..512 + size], draft().config_yaml().as_bytes());
    let second = 512 + size.next_multiple_of(512);
    assert_eq!(&archive[second..second + 9], b"AGENTS.md");
    let checksum: u64 = archive[..512]
        .iter()
        .enumerate()
        .map(|(index, byte)| {
            if (148..156).contains(&index) {
                u64::from(b' ')
            } else {
                u64::from(*byte)
            }
        })
        .sum();
    let stored = u64::from_str_radix(std::str::from_utf8(&archive[148..154]).unwrap(), 8).unwrap();
    assert_eq!(stored, checksum);
}

#[test]
fn large_and_empty_data_split_into_valid_blocks() {
    let large = vec![b'x'; 70_000];
    assert_eq!(gunzip_stored(&gzip_stored(&large)), large);
    assert_eq!(gunzip_stored(&gzip_stored(&[])), Vec::<u8>::new());
}

#[test]
fn key_value_lines_take_equals_or_colon() {
    let parsed = key_value_lines("A=1\nAuthorization: Bearer x\nnope\n=bad");
    assert_eq!(parsed.get("A").map(String::as_str), Some("1"));
    assert_eq!(
        parsed.get("Authorization").map(String::as_str),
        Some("Bearer x")
    );
    assert_eq!(parsed.len(), 2);
}

#[test]
fn config_patch_sends_only_changes() {
    let current = AgentConfig::from_value(
        &json!({
            "id": "a1", "name": "reviewer", "version": 3, "description": "Old",
            "instructions": "Hi", "model": "m1", "harness": "codex",
            "mcp_servers": {"fs": {"transport": "stdio", "command": "npx", "args": ["-y"],
                                    "editable": true}}
        }),
        Some("\"etag\"".into()),
    )
    .unwrap();
    assert_eq!(current.mcp_servers[0].args, ["-y"]);
    let unchanged = AgentConfigEdit {
        description: "Old".into(),
        instructions: "Hi".into(),
        model: "m1".into(),
        harness: "codex".into(),
        removed_mcp_servers: Vec::new(),
    };
    assert_eq!(config_patch(&current, &unchanged), Ok(json!({})));
    let changed = AgentConfigEdit {
        description: String::new(),
        model: "m2".into(),
        removed_mcp_servers: vec!["fs".into()],
        ..unchanged.clone()
    };
    assert_eq!(
        config_patch(&current, &changed),
        Ok(json!({"description": null, "model": "m2", "mcp_servers": {"fs": null}}))
    );
    let blank = AgentConfigEdit {
        harness: " ".into(),
        ..unchanged
    };
    assert!(config_patch(&current, &blank).is_err());
}

#[test]
fn managed_agents_label_their_harness() {
    let agent = ManagedAgent::from_value(
        &json!({"id": "a", "name": "x", "harness": "claude-sdk", "created_at": 5}),
    )
    .unwrap();
    assert_eq!(agent.harness_label(), "Claude SDK");
    assert_eq!(agent.created_at, Some(5));
    assert!(!agent.builtin);
}
