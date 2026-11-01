# Terminal fixtures

Captured on 2026-10-31 from a local server started from this repo in an isolated directory
(`omnigent server` on 127.0.0.1:6798 plus `omnigent host`, single-user, the built-in `polly`
agent, which declares the `shell` and `zsh` terminals). The `direct_attach_url` tokens are
replaced with `redacted-capture-token`; nothing else is edited.

- `recorded-{create,create-idempotent,create-undeclared,get,get-missing,list,delete,delete-missing}.json`:
  `{request: {method, path, body}, status, body}` for one REST call.
- `recorded-attach-*.jsonl`: one attach WebSocket per file, one frame per line:
  - `{"direction": "recv"|"send", "kind": "binary", "base64": ...}` for pane output or input;
  - `{"direction": "recv"|"send", "kind": "text", "text": ...}` for JSON control frames;
  - `{"direction": "close", "code", "reason", "expect"}` for the server's close, with the state the
    client must reach (`terminal_ended`, `detached`, `server_closed`, `reconnecting`, `failed`).

`recorded-attach-shell-echo.jsonl` attaches, resizes to 100x30 and runs one command.
`recorded-attach-exit.jsonl` runs `exit`, so the server closes with 4404. `recorded-attach-missing.jsonl`
attaches to a deleted terminal.
`recorded-attach-repl-tui.jsonl` attaches to `terminal_tui_main`, the embedded Omnigent REPL TUI
of a terminal-first (`omnigent.ui = terminal`) SDK session: truecolor, box drawing, an OSC 11
query and cursor-addressed redraws. It types a draft, moves the cursor, resizes to 120x36 and
clears the draft; no message is submitted, so no model provider is called. Rust consumers: `omnigent-core` `terminal::fixture_tests` and
`terminal::attach::tests::replays_*`.
