# Decision (elicitation and permission) fixtures

Formats:

- **`.json`**: one payload, or one HTTP exchange envelope.
- **`.jsonl`**: an ordered sequence, one JSON value per line:
  - an event sequence: one stream event object (the SSE `data:` payload) per line, in apply order;
  - SSE frames: `{id, event, data, raw?}`, where `data` is parsed JSON when the payload is JSON;
    `raw` is the exact frame text and is present where bytes matter;
  - an HTTP script: one envelope per line, served in file order per (method, path);
  - WebSocket: `{direction: "send"|"recv", message}`.
- **HTTP envelope**:
  - `{"request": {"method", "path", "query"?, "body"?}, "status", "headers"?, "response"}`.
  - `response` is a string when the body is not JSON. `error` replaces status and response for transport failures.
  - Optional fields: `response_url`, `delay_ms`, and `response_base64`/`response_generated` for binary bodies.
  - `query` lists only the parameters the test asserts.
  - Hosted and Databricks paths include the mount `/api/2.0/omnigent`.

Naming:

- `recorded-*` was captured from a real server; see below.
- `<SwiftSuiteStem>--<TestNameWithoutTestPrefix>[--<label>]` was extracted from that NativeLab test (see
  `client-core/docs/port-checklist.md` for the Rust test that uses it).
- `<Suite>--_shared--*` is a payload shared by several tests in one suite.
- `EventGallery--*` and `DemoFixtures--*` come from `EventGalleryFixtures.swift` and `DemoFixtures.swift`.

Fixtures carry inputs only. Each bullet below states the expected outcome, and the Rust test asserts it.
Swift string interpolation was resolved to the concrete values each test uses, and loops were unrolled in order.

## Extracted from reducer-side NativeLab tests

- `DecisionForm--ArrayChoicesValidateCountAndMembership.json`: Array field 'tags' with minItems 1, maxItems 2, enum items One/Two/Three. Expect ['One','Two'] valid; ['Other'] invalid (membership); three items invalid (count); duplicate ['One','One'] invalid.
- `DecisionForm--AskUserQuestionPreservesIDsAndSupportsCustomAndMultiAnswers.json`: AskUserQuestion with two questions: 'scope' (id kept, single select, option Native described as 'Phone UI') and 'What next?' (multi select, no id). Expect field keys ['scope','What next?']; custom answer for scope and multi answer for next is valid; scope answered with the option only is invalid.
- `DecisionForm--CommandPolicyAndMetadataRemainExplicit.json`: Command approval with command 'swift test', cwd /workspace, reason 'Verify the change', execpolicy amendment [swift,test]. Expect execPolicyAmendment ['swift','test'] and detail containing 'Working directory: /workspace' and 'Reason: Verify the change'.
- `DecisionForm--DecisionValuesEncodeAsFlatMCPScalars.json`: Flat MCP wire form of a decision form value set: string, number, boolean, string array. Expect encoding to plain JSON scalars/arrays and decode back to the same values.
- `DecisionForm--ExternalRequestOnlyExposesSafeExplicitHandoff.jsonl`: Two URL-mode requests: https URL (externalURL kept, still unsupported) and javascript: URL (externalURL nil, unsupportedReason set). Expect only the https link exposed as a handoff.
- `DecisionForm--MalformedConstraintsFailClosed.jsonl`: Five independent malformed schemas (required as string, fractional minLength, negative minLength, string minimum, minimum greater than maximum). Each must fail closed with unsupportedReason.
- `DecisionForm--MalformedQuestionCannotBecomeApproval.json`: AskUserQuestion question with no options. Expect unsupportedReason non-nil and form nil.
- `DecisionForm--PlanAndRememberCapabilitiesAreExplicit.jsonl`: Plan review (isPlanReview true, allowAllEdits true) and remember-scope request (rememberLabel 'example.invalid'). Expect both capabilities explicit.
- `DecisionForm--QuestionPreviewFallbackProducesForm.json`: No structured question, only a content_preview string containing an AskUserQuestion call. Expect a form whose first field key is 'Continue?'.
- `DecisionForm--SchemaWithoutPropertiesAndMissingURLNeverBecomeApproval.jsonl`: Four independent cases (array schema, oneOf schema, url mode without URL, non-object schema). Each must have a non-nil unsupportedReason.
- `DecisionForm--TypedSchemaHasNativeFieldsAndValidatesWithoutCoercion.json`: Typed object schema with string(minLength 2), integer(1-5), boolean; all required. Expect a form (no unsupportedReason). Validation: empty values invalid; name 'Omni', count 2, ready false valid; name 'O' invalid; count 2.5 invalid; count '2' (string) invalid.
- `DecisionForm--UnsupportedNestedSchemaNeverBecomesApproval.json`: Nested object property. Expect unsupportedReason non-nil and form nil.
- `DecisionForm--UnsupportedPatternNeverSilentlyDisappears.json`: String property with a pattern constraint. Expect unsupportedReason non-nil (not silently dropped).
- `EventParity--UnsupportedSchemaAndIncompleteURLModeCannotBecomeBinaryApproval.jsonl`: Three independent elicitation payloads (array schema, oneOf schema, url mode without URL). Each must decode with a non-nil unsupportedReason and never become a binary approval.
- `LiveConversationReducer--MultiFieldFormsUseTypedFieldsInsteadOfBinaryApprovals.json`: Multi-field form with no top-level type: name (text) and count (integer). Expect no unsupportedReason, no binary options, field keys sorted as ['count','name'] with kinds [integer,text].

## Extracted from client-side NativeLab tests

- `LocalServerSessionClient--ExplicitPermissionResponsesMatchMainAppWire--allow-all-edits.jsonl`: 2 HTTP exchange(s) in order: GET /v1/sessions/conv_a; POST /v1/sessions/conv_a/elicitations/permission1/resolve; used by LocalServerSessionClientTests.swift::testExplicitPermissionResponsesMatchMainAppWire; expected: four permission responses (allow-all-edits, remember, exit-plan decline with feedback, command policy) match the main-app content wire.
- `LocalServerSessionClient--ExplicitPermissionResponsesMatchMainAppWire--command-policy.jsonl`: 2 HTTP exchange(s) in order: GET /v1/sessions/conv_a; POST /v1/sessions/conv_a/elicitations/permission1/resolve; used by LocalServerSessionClientTests.swift::testExplicitPermissionResponsesMatchMainAppWire; expected: four permission responses (allow-all-edits, remember, exit-plan decline with feedback, command policy) match the main-app content wire.
- `LocalServerSessionClient--ExplicitPermissionResponsesMatchMainAppWire--exit-plan-mode.jsonl`: 2 HTTP exchange(s) in order: GET /v1/sessions/conv_a; POST /v1/sessions/conv_a/elicitations/permission1/resolve; used by LocalServerSessionClientTests.swift::testExplicitPermissionResponsesMatchMainAppWire; expected: four permission responses (allow-all-edits, remember, exit-plan decline with feedback, command policy) match the main-app content wire.
- `LocalServerSessionClient--ExplicitPermissionResponsesMatchMainAppWire--remember-scope.jsonl`: 2 HTTP exchange(s) in order: GET /v1/sessions/conv_a; POST /v1/sessions/conv_a/elicitations/permission1/resolve; used by LocalServerSessionClientTests.swift::testExplicitPermissionResponsesMatchMainAppWire; expected: four permission responses (allow-all-edits, remember, exit-plan decline with feedback, command policy) match the main-app content wire.
- `LocalServerSessionClient--InvalidStructuredFormDoesNotPostOrBecomeApproval.jsonl`: 1 HTTP exchange(s) in order: GET /v1/sessions/conv_a; used by LocalServerSessionClientTests.swift::testInvalidStructuredFormDoesNotPostOrBecomeApproval; expected: invalid typed forms (out-of-range, string for int, empty, approve) fail invalidDecision and never POST.
- `LocalServerSessionClient--QuestionResolutionUsesRequestedAnswerKey.jsonl`: 2 HTTP exchange(s) in order: GET /v1/sessions/conv_a; POST /v1/sessions/conv_a/elicitations/ask1/resolve; used by LocalServerSessionClientTests.swift::testQuestionResolutionUsesRequestedAnswerKey; expected: a single-select question resolves as accept with content keyed by the requested field name.
- `LocalServerSessionClient--StructuredFormPostsTypedContentWithoutCoercion.jsonl`: 2 HTTP exchange(s) in order: GET /v1/sessions/conv_a; POST /v1/sessions/conv_a/elicitations/form1/resolve; used by LocalServerSessionClientTests.swift::testStructuredFormPostsTypedContentWithoutCoercion; expected: typed form values resolve as accept with exact JSON types (string, number, bool, string array).
- `LocalServerSessionClient--TypedQuestionNeverPostsBinaryApproval.jsonl`: 1 HTTP exchange(s) in order: GET /v1/sessions/conv_a; used by LocalServerSessionClientTests.swift::testTypedQuestionNeverPostsBinaryApproval; expected: a typed question cannot be answered with a binary approve; no POST is made.
- `LocalServerSessionClient--UnadvertisedPermissionOptionsNeverPost.jsonl`: 1 HTTP exchange(s) in order: GET /v1/sessions/conv_a; used by LocalServerSessionClientTests.swift::testUnadvertisedPermissionOptionsNeverPost; expected: permission options absent from requestedSchema are rejected invalidDecision before any POST.

## Hand-built from the server's request shapes

- `FileChanges--ServerApprovalShapes.json`: elicitation requests keyed by label, each built with the
  formula of the server code that sends it: `routes_hooks.py` (native `PermissionRequest` hooks:
  `ToolName(<json.dumps(tool_input)[:1024]>)` plus `tool_name`), `_executor_adapter.py` (SDK
  harnesses, 300-character cap), `orchestration.py` policy evaluation
  (`json.dumps({"name", "arguments"})[:1024]`) and `_codex_elicitation.py` (`applyPatchApproval`
  with `fileChanges` and the sorted `files` list; `item/fileChange/requestApproval`, which carries
  no changes). The Codex `FileChange` uses the `{"type": ...}` tagging. Expected file changes:
  - `claude-edit`: `auth/session.rs`, modify, +3 −1; the message and the tool input come apart.
  - `claude-edit-cut`: the preview is cut inside `old_string`: the path, modify, no counts.
  - `claude-multiedit`: `README.md`, modify, +2 −1 (the batch's edits added up).
  - `claude-write`: `docs/notes.md`, write, +4, removals unknown.
  - `claude-notebook`: `analysis.ipynb`, modify, an inserted cell: +2 −0.
  - `claude-bash`: no files.
  - `devin-edit` (`oldText`/`newText` keys): `/repo/app.py`, modify, +1 −1.
  - `pi-sdk-write-cut`: cut inside an escape in `content`: the path, write, no counts.
  - `policy-sys-os-edit` (`mcp__omnigent__sys_os_edit`): `/repo/src/lib.rs`, modify, +1 −0.
  - `policy-apply-patch` (`changes: [{path, kind, diff}]`): `new.rs` create +1 −0, `old.rs`
    delete +0 −2, `main.rs` modify +1 −1, in that order.
  - `codex-apply-patch`: in `files` order, `main.rs` modify +2 −1, `new.rs` create +1 −0,
    `old.rs` delete +0 −1.
  - `codex-apply-patch-cut`: cut inside `big.rs`: `a.rs` modify +1 −1, `big.rs` create without
    counts, `z.rs` with no kind or counts (listed only in `files`).
  - `codex-file-change`: no files.
