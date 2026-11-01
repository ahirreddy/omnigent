# Workspace file-route fixtures

Each `recorded-*.json` file is one HTTP exchange envelope (`request`, `status`, `response`), in the format described in `../sessions/README.md` (see "Formats" and "HTTP envelope" there). `response` is the parsed JSON body. `query` lists the query parameters sent. Paths are the percent-encoded URL paths as sent.

## Recorded from a live server

Recorded on 2026-10-31 from this repo's own server, `python -m omnigent server` on 127.0.0.1:17431, with an isolated config, data and HOME directory under `/private/tmp/claude-502/ws-server`. Loopback single-user mode, no auth headers.

- Runner: a sibling `python -P -m omnigent.runner._entry`, started the way `omnigent/cli.py::_start_cli_runner_process` starts it (a tunnel binding token, the runner id derived from it with `token_bound_runner_id`, and `OMNIGENT_RUNNER_WORKSPACE` set to the workspace). The session was bound with `PATCH /v1/sessions/{id} {runner_id}`.
- Agent: the `fixture_agent` bundle from the sessions README (harness `openai-agents`, model `mock-model`, `os_env` `caller_process`, `cwd: .`, `sandbox: none`). No message was sent to the session, so the scripted Responses-API mock (`tests/server/integration/mock_llm_server.py`) was not started and no model call happened. The runner came online and accepted the bind without one.
- Session id `207c660071e248e198c634aec763bb75` (real). Session upload id `56089d9c5df645a1befb01b03c0ac9da` (real).
- Feature flag: the server ran with `OMNIGENT_FEATURES=workspace_content_search` for every content-search fixture. It was restarted without the flag to record `recorded-content-search-flag-off.json`, then restarted again with the flag to check result ordering. Content search also needs `rg` on PATH (`/opt/homebrew/bin/rg`).
- Workspace: a git repository at `/private/tmp/claude-502/ws-server/workspace` with one commit (`seed fixture workspace`). Tracked: `.gitignore` (`target/`, `*.log`), `README.md`, `src/main.rs`, `src/lib.rs`, `src/util/mod.rs`, `assets/logo.png` (8x8 RGB PNG, 165 bytes), and `docs/café notes.md` (NFC name, with an accented word and an emoji line). Ignored: `build.log`.
- Pristine captures (filesystem, file, search, content search, environments) were recorded before the workspace was changed. Then the changes below were made on disk, not committed: `src/main.rs` got two added lines (modified), `src/new_file.rs` was created (untracked), `src/util/mod.rs` was deleted, and `src/lib.rs` was renamed to `src/library.rs` with `git mv` (staged). Then the changes, diff, and session-file captures were taken.
- Placeholders: the workspace prefix is replaced with `/workspace/fixture` (in `base`, `root`, and the `roots` entries); the isolated HOME with `/home/fixture`; any other prefix of the temp directory with `/fixture-server`; runner ids with `runner_token_placeholder`. Timestamps, sizes and ids are real.

## Fixtures

Filesystem listing:

- `recorded-filesystem-root.json`: `GET .../filesystem?limit=1000&order=asc` -> 200, `{object: "list", base, data, first_id, last_id, has_more}`. Seven entries in name order: `.git`, `.gitignore`, `README.md`, `assets`, `build.log`, `docs`, `src`. Directories have `bytes: null`. The gitignored `build.log` is listed, since listing does not apply `.gitignore`. `has_more` is false.
- `recorded-filesystem-page-1.json`: `limit=2&order=asc` with no cursor -> 200, data `[.git, .gitignore]`, `has_more: true`, `last_id: ".gitignore"`.
- `recorded-filesystem-page-2.json`: `limit=2&order=asc&after=.gitignore` -> data `[README.md, assets]`, `has_more: true`.
- `recorded-filesystem-page-3.json`: `limit=2&order=asc&after=assets` -> data `[build.log, docs]`, `has_more: true`.
- `recorded-filesystem-page-4.json`: `limit=2&order=asc&after=docs` -> data `[src]`, `first_id` and `last_id` `src`, `has_more: false`. Together the four pages cover the root exactly once.
- `recorded-filesystem-src.json`: `GET .../filesystem/src?limit=1000&order=asc` -> 200, `base` is `/workspace/fixture/src`. Entry `id` and `path` are workspace-relative (`src/lib.rs` with `bytes: 99`, `src/main.rs` with `bytes: 90`, and `src/util` as a directory with `bytes: null`). `name` is the basename.

File reads:

- `recorded-file-text.json`: `GET .../filesystem/src/main.rs` -> 200, `{object: "session.environment.filesystem.file_content", path, content_type, bytes: 90, truncated: false, encoding: "utf-8", content}`. `content` is the plain text. `content_type` is `application/rls-services+xml`, which is what the Python `mimetypes` table on the recording machine returns for `.rs` (see caveats).
- `recorded-file-binary.json`: `GET .../filesystem/assets/logo.png` -> 200, same envelope with `content_type: "image/png"`, `bytes: 165`, `encoding: "base64"`. `content` is the base64 of the PNG bytes (it begins `iVBORw0KGgo`).
- `recorded-file-nonascii.json`: `GET .../filesystem/docs/caf%C3%A9%20notes.md` (percent-encoded per segment) -> 200. `path` comes back decoded as `docs/café notes.md`. `content_type: "text/markdown"`, `bytes: 73` (the UTF-8 byte count), `encoding: "utf-8"`.
- `recorded-file-missing.json`: `GET .../filesystem/missing.txt` -> 404, `{"error": {"code": "not_found", "message": "Path 'missing.txt' not found"}}`.
- `recorded-file-traversal-dotdot.json`: `GET .../filesystem/src/%2E%2E/%2E%2E/etc/passwd` -> 400, `{"error": {"code": "invalid_input", "message": "Parent path segments are not permitted"}}`. The route rejects it before any read; no 404 or 200 is returned for the target.
- `recorded-file-traversal-encoded-slash.json`: `GET .../filesystem/src/..%2F..%2Fetc%2Fpasswd` -> 400, the same error body.

Path search:

- `recorded-search-root.json`: `GET .../search?q=main&limit=500` -> 200, `{object, base, data, has_more, truncated}`. One entry, `src/main.rs` (workspace-relative, `type: "file"`, `bytes: 90`).
- `recorded-search-src.json`: `GET .../search/src?q=lib&limit=500` -> 200, `base` is `/workspace/fixture/src`. The single entry has `id` and `path` both `lib.rs`, relative to the searched directory. Root search uses workspace-relative paths, so the two routes differ in what `path` is relative to.

Content search (all require the feature flag):

- `recorded-content-search.json`: `GET .../content-search?q=fixture needle&case_sensitive=false&regex=false&include=&exclude=&limit=500` -> 200, `{matches, truncated: false, warning: null}`. Seven matches: `README.md` (lines 3 and 4, the second is "Fixture Needle", so the match is case-insensitive), `src/main.rs` (lines 2 and 3), `src/lib.rs` (line 3), and `docs/café notes.md` (lines 3 and 4). Each match is `{path, line, column, text, match_start, match_end}`. `line` and `column` are 1-based. `match_start` and `match_end` are UTF-16 code-unit offsets into `text`: on the café line `match_start` is 13, where the UTF-8 byte offset would be 15.
- `recorded-content-search-regex.json`: `q=fixture\s+needle` with `regex=true` -> 200, the same seven matches.
- `recorded-content-search-invalid-regex.json`: `q=(unclosed` with `regex=true` -> 200, `{"error": "regex parse error:\n    (unclosed\n    ^\nerror: unclosed group"}`. There is no `matches` key, and `error` is a bare string, not the `{code, message}` object the other routes use.
- `recorded-content-search-globs.json`: `q=fixture needle&include=src/**&exclude=**/main.rs` -> 200, one match: `src/lib.rs` line 3, `match_start: 4`, `match_end: 18`.
- `recorded-content-search-unicode.json`: `q=needle again` -> 200, one match: `docs/café notes.md` line 4, `column: 12`, `text` is the line that starts with U+1F600 (a 4-byte, 2-UTF-16-unit character) followed by " fixture needle again.", `match_start: 11`, `match_end: 23`. The emoji is two UTF-16 units. The UTF-8 byte offset of the match would be 13.
- `recorded-content-search-flag-off.json`: the same query as the first content search, sent to a server without `OMNIGENT_FEATURES=workspace_content_search` -> 404, `{"detail": "Workspace content search is disabled"}`. This is FastAPI's `HTTPException` body, not the `{error: {code, message}}` shape.

Changes and diffs (workspace state described in "Recorded from a live server"):

- `recorded-changes.json`: `GET .../changes` -> 200, `{object: "list", data, has_more: false}`. Four entries, each `{object: "session.environment.filesystem.entry", path, name, status, bytes, modified_at, lines_added, lines_removed}`:
  - `src/new_file.rs`: `status: "created"`, `bytes: 38`, `lines_added: null`, `lines_removed: null`.
  - `src/main.rs`: `status: "modified"`, `bytes: 129`, `lines_added: 2`, `lines_removed: 0`.
  - `src/library.rs`: `status: "modified"`, `bytes: 99`, `lines_added: 6`, `lines_removed: 0`. This is the staged rename of `src/lib.rs`. There is no `renamed` status and no entry for `src/lib.rs`.
  - `src/util/mod.rs`: `status: "deleted"`, `bytes: null`, `modified_at: null`, `lines_added: 0`, `lines_removed: 3`.
- `recorded-diff-modified.json`: `GET .../diff/src/main.rs` -> 200, `{object: "session.environment.filesystem.file_diff", path, before, after}`. `before` is the committed text and `after` is the working-tree text, both as full strings.
- `recorded-diff-created.json`: `GET .../diff/src/new_file.rs` -> 200, `before: null`, `after` is the full file.
- `recorded-diff-deleted.json`: `GET .../diff/src/util/mod.rs` -> 200, `before` is the full committed file, `after: null`.
- `recorded-diff-unchanged.json`: `GET .../diff/.gitignore` -> 404, `{"error": {"code": "not_found", "message": "Path '.gitignore' is not in the changed-files registry for this session"}}`.
- `recorded-diff-renamed-new.json`: `GET .../diff/src/library.rs` -> 200, `before: null`, `after` is the full file. The staged rename is diffed as a new file, not against `src/lib.rs`.

Environments and session files:

- `recorded-environments.json`: `GET /v1/sessions/{id}/resources/environments` -> 200, `{object: "list", data, first_id, last_id, has_more}` with two entries: `env_terminal_tui_main` (`metadata.role: "terminal"`, `terminal_name: "tui"`, `session_key: "main"`, `sandbox_type: "none"`) and `default` (`metadata.role: "primary"`). The runner created the terminal environment on its own; no request made it.
- `recorded-environment-default.json`: `GET .../environments/default` -> 200, `{id: "default", object: "session.resource", type: "environment", session_id, name: "Primary environment", metadata}`. `metadata` has `environment_type: "caller_process"`, `role: "primary"`, `root`, `home`, and `reachable: {unconfined: true, roots: [{path, access: "write", origin: "cwd"}]}`.
- `recorded-session-file-upload.json`: `POST /v1/sessions/{id}/resources/files`, multipart part `file` (`fixture-upload.txt`, 23 bytes, `text/plain`) -> 201, `{id, object: "session.resource", type: "file", session_id, name, metadata: {filename, bytes: 23, created_at, source_metadata: null}}`.
- `recorded-session-files.json`: `GET /v1/sessions/{id}/resources/files?limit=20` -> 200, `{object: "list", data, first_id, last_id, has_more: false}` with the one upload above.

## Caveats

- Content-search match order is not stable. `rg --json` runs without `--sort` (see `omnigent/runner/content_search.py`). The same query returned README first on one run and `src/main.rs` first on another, with the same workspace. Compare matches as a set, or sort them, in tests.
- `content_type` for `.rs` (`application/rls-services+xml`) comes from Python's `mimetypes` table on the recording machine, so it can differ between hosts.
- `bytes` in `file_content` is the number of bytes returned. A 10 MiB cap applies (`_MAX_READ_BYTES`). Two scratch files, deleted afterwards and not recorded, showed the behavior: an 11 MiB text file came back with `bytes: 10485760` and `truncated: true`, and a text file of about 300 KB came back whole (`bytes: 334523`, `truncated: false`). The 300 KB response is over the fixture size budget, so it is not stored.
- The gitignored `build.log` is excluded from content search results. This was checked with a live query, not recorded.
- The runner's first start exited during that probe (its parent-pid check failed), which left a `mtime-test-*/` directory in the workspace. Git's untracked-cache probe creates it, and the probe also sets `core.untrackedCache=true` in the workspace's `.git/config`. The stale directory was removed before the pristine captures, so no listing or change in these fixtures includes it.
