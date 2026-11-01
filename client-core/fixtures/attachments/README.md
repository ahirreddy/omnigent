# Attachment and upload fixtures

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

- `AttachmentDraft--SupportedTypesExactCapsAndFilenameValidation.json`: Supported types with exact per-type caps (limitMiB: the file at exactly the cap is accepted, cap+1 byte is rejected as tooLarge), unsupported extensions, invalid filenames (empty, traversal, CRLF, backslash), and a media type containing CRLF. Expect accept/reject as listed.
- `AttachmentDraft--TransportAndStoreKeepExactRefsAfterRejectedSendAndBlockUncertainRetry.json`: Canned transport responses: denied submit (HTTP 202, body queued false / denied true) and a network-connection-lost error for the uncertain retry, plus the retained file bytes and submitted text. Expect exactly one file upload POST, two event POSTs, draft retaining attachments, and beginSubmission blocked after uncertain.

## Extracted from client-side NativeLab tests

- `DatabricksRouting--AttachmentReferencesResolveWithScopeQueryAndRejectDifferentOrg.json`: fixture object; used by DatabricksRoutingTests.swift::testAttachmentReferencesResolveWithScopeQueryAndRejectDifferentOrg; expected: attachment refs accept ?o=123 scope and reject ?o=456, duplicated or encoded org queries, and other hosts.
- `DatabricksRouting--UploadsAndPreviewRequestsPreserveScopeAndRejectCrossOrgAttachments.jsonl`: 3 HTTP exchange(s) in order: GET /api/2.0/omnigent/v1/sessions/a; POST /api/2.0/omnigent/v1/sessions/a/resources/files; GET /api/2.0/omnigent/v1/sessions/a/resources/files/file_a/content; used by DatabricksRoutingTests.swift::testUploadsAndPreviewRequestsPreserveScopeAndRejectCrossOrgAttachments; expected: upload and preview keep the org scope; an attachment from another org is rejected with no request.
- `HostedServerAuthentication--AttachmentReferencesStayWithinMountAndIdentity.json`: fixture object; used by HostedServerAuthenticationTests.swift::testAttachmentReferencesStayWithinMountAndIdentity; expected: attachment refs resolve only within this mount and account; other hosts, ports, query strings and other users are rejected.
- `HostedServerAuthentication--MountedUploadCarriesBearerAndReturnedAttachmentIdentity.jsonl`: 2 HTTP exchange(s) in order: GET /api/2.0/omnigent/v1/sessions/a; POST /api/2.0/omnigent/v1/sessions/a/resources/files; used by HostedServerAuthenticationTests.swift::testMountedUploadCarriesBearerAndReturnedAttachmentIdentity; expected: mounted upload carries the bearer; the returned attachment is bound to the server URL and user ID.
- `LocalAttachment--AdvertisedContentLengthOverLimitIsRejected.json`: HTTP GET /v1/sessions/fixture/resources/files/file/content -> 200; used by LocalAttachmentTests.swift::testAdvertisedContentLengthOverLimitIsRejected; expected: a Content-Length above 10 MiB is rejected as tooLarge before the body is read.
- `LocalAttachment--ExplicitFetchUsesSessionResourceGETAndPreservesBytesWithoutCredentials.json`: HTTP GET /v1/sessions/fixture/resources/files/file_1/content -> 200; used by LocalAttachmentTests.swift::testExplicitFetchUsesSessionResourceGETAndPreservesBytesWithoutCredentials; expected: attachment fetch is a session-scoped GET that returns the exact bytes, png extension, and no credentials.
- `LocalAttachment--RedirectsDifferentResponseOriginsAndHTTPFailuresAreExplicit.jsonl`: 6 HTTP exchange(s) in order: GET /v1/sessions/fixture/resources/files/file/content; GET /v1/sessions/fixture/resources/files/file/content; GET /v1/sessions/fixture/resources/files/file/content ...; used by LocalAttachmentTests.swift::testRedirectsDifferentResponseOriginsAndHTTPFailuresAreExplicit; expected: 302, cross-origin response, 401, 403, 404 and 500 each map to an explicit error; 401 revokes reads until reconnect.
- `LocalAttachment--ReferenceResolutionAcceptsOnlyExactSessionResources.json`: table of 21 case(s); used by LocalAttachmentTests.swift::testReferenceResolutionAcceptsOnlyExactSessionResources; expected: only exact same-server, same-session resource references resolve to a file ID; other hosts, queries, fragments, traversal, data: and file: URLs do not.
- `LocalAttachment--StreamingLengthLimitDoesNotTrustMissingContentLength.json`: HTTP GET /v1/sessions/fixture/resources/files/file/content -> 200; used by LocalAttachmentTests.swift::testStreamingLengthLimitDoesNotTrustMissingContentLength; expected: a streamed body over 10 MiB with no Content-Length is rejected as tooLarge.
- `LocalAttachment--SupportedMIMETypesHaveFixedSafeExtensions--mime-table.json`: HTTP GET /v1/sessions/fixture/resources/files/file/content -> None; used by LocalAttachmentTests.swift::testSupportedMIMETypesHaveFixedSafeExtensions; expected: 17 supported MIME types map to fixed safe extensions; charset parameters are ignored.
- `LocalAttachment--UnsupportedActiveOrUnknownMIMEIsRejected.jsonl`: 5 HTTP exchange(s) in order: GET /v1/sessions/fixture/resources/files/file/content; GET /v1/sessions/fixture/resources/files/file/content; GET /v1/sessions/fixture/resources/files/file/content ...; used by LocalAttachmentTests.swift::testUnsupportedActiveOrUnknownMIMEIsRejected; expected: text/html, SVG, JavaScript, octet-stream and a missing MIME type are unsupportedMedia.
- `LocalServerUpload--IndeterminateUploadFailuresDoNotRetryPOST.jsonl`: 6 HTTP exchange(s) in order: POST /v1/sessions/session_a/resources/files; POST /v1/sessions/session_a/resources/files; POST /v1/sessions/session_a/resources/files ...; used by LocalServerUploadTests.swift::testIndeterminateUploadFailuresDoNotRetryPOST; expected: uncertain upload outcomes (500, bad body, wrong ID, transport loss, cancel, redirected URL) are uploadUncertain and not retried.
- `LocalServerUpload--MessageUsesUploadedRefsBeforeExactTextAndSupportsAttachmentsOnly.jsonl`: 4 HTTP exchange(s) in order: POST /v1/sessions/session_a/resources/files; POST /v1/sessions/session_a/resources/files; POST /v1/sessions/session_a/events ...; used by LocalServerUploadTests.swift::testMessageUsesUploadedRefsBeforeExactTextAndSupportsAttachmentsOnly; expected: message content lists uploaded image and file refs before the exact text; an attachment-only message omits text.
- `LocalServerUpload--RejectedUploadCanBeReportedWithoutSendingTranscriptMessage.jsonl`: 4 HTTP exchange(s) in order: POST /v1/sessions/session_a/resources/files; POST /v1/sessions/session_a/resources/files; POST /v1/sessions/session_a/resources/files ...; used by LocalServerUploadTests.swift::testRejectedUploadCanBeReportedWithoutSendingTranscriptMessage; expected: 403, 413 and 415 uploads surface explicit errors; 401 revokes the connection; no transcript message is sent.
- `LocalServerUpload--Upload201UsesExactMultipartFieldBytesAndSafeSessionTransport.json`: HTTP POST /v1/sessions/session_a/resources/files -> 201; used by LocalServerUploadTests.swift::testUpload201UsesExactMultipartFieldBytesAndSafeSessionTransport; expected: upload posts multipart with the escaped filename and exact bytes, returns the server file ID, and sends no auth, cookie or origin headers.
- `LocalServerUpload--UploadFallbackFilenameMatchesWebContract.json`: HTTP POST /v1/sessions/session_a/resources/files -> 201; used by LocalServerUploadTests.swift::testUploadFallbackFilenameMatchesWebContract; expected: when the upload response has no metadata filename, the requested filename is kept and a non-image is not treated as image.
