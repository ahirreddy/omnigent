// OWL wire schema: the single source of truth for messages between the Omnigent Web Layer
// client (Swift, OmnigentWebLayer) and the web host (Omnigent Web Host.app). Both sides compile
// against this header. See ../../../DESIGN.md, "IPC".
//
// Compatibility rules:
// - Message kinds and field tags are never renumbered or reused.
// - A minor version may add kinds and fields. Receivers skip unknown fields and report unknown
//   kinds as errors (never silently).
// - Anything else is a major version change; the handshake rejects a major mismatch.
#pragma once

#include <CoreFoundation/CFAvailability.h>
#include <stdint.h>

#define OWL_PROTOCOL_MAJOR 1
#define OWL_PROTOCOL_MINOR 3

/// The first minor version with projected browser UI (prompts, downloads, popups, IME, drag and
/// drop). Each side enables those features only when the peer advertises at least this minor;
/// otherwise the host keeps blocking them as in 1.0.
#define OWL_PROTOCOL_MINOR_PROMPTS 1

/// The first minor version with browsing state for a full browser: favicons, navigation history
/// for session restore, audible state and per-view mute, and hard reload. Each side sends these
/// only when the peer advertises at least this minor.
#define OWL_PROTOCOL_MINOR_BROWSING 2

/// The first minor version with sign-in plumbing: local-network permission requests (Okta
/// FastPass and device-trust agents probe 127.0.0.1) and custom-scheme hand-off to native apps
/// (`com-okta-authenticator:`). Older clients get them as OWLPermissionOther and FeatureBlocked.
#define OWL_PROTOCOL_MINOR_SIGN_IN 3

/// Payload encoding: a sequence of fields, each an 8-byte header followed by `length` bytes.
/// Integers and floats are little-endian. Strings are UTF-8 without a terminator.
typedef CF_ENUM(uint8_t, OWLFieldType) {
  OWLFieldTypeUInt64 = 1,
  OWLFieldTypeInt64 = 2,
  OWLFieldTypeDouble = 3,
  OWLFieldTypeBool = 4,
  OWLFieldTypeString = 5,
  OWLFieldTypeBytes = 6,
};

/// Field header. `tag` is an OWLField value.
typedef struct OWLFieldHeader {
  uint16_t tag;
  uint8_t type;
  uint8_t reserved;
  uint32_t length;
} OWLFieldHeader;

/// Field tags. One namespace for every message; each message lists the tags it uses below.
typedef CF_ENUM(uint16_t, OWLField) {
  OWLFieldProtocolMajor = 1,
  OWLFieldProtocolMinor = 2,
  OWLFieldToken = 3,
  OWLFieldHostPID = 4,
  OWLFieldCEFVersion = 5,
  OWLFieldChromiumVersion = 6,
  OWLFieldAccepted = 7,
  OWLFieldReason = 8,
  OWLFieldRootCachePath = 9,
  OWLFieldLocale = 10,
  OWLFieldRemoteDebuggingPort = 11,
  OWLFieldUseMockKeychain = 12,
  OWLFieldKeychainService = 13,
  OWLFieldRenderMode = 14,
  OWLFieldElapsedMilliseconds = 15,
  OWLFieldErrorCode = 16,
  OWLFieldMessage = 17,
  OWLFieldProfileID = 18,
  OWLFieldStorageKey = 19,
  OWLFieldPersistent = 20,
  OWLFieldURL = 21,
  OWLFieldWidth = 22,
  OWLFieldHeight = 23,
  OWLFieldScale = 24,
  OWLFieldVisible = 25,
  OWLFieldFocused = 26,
  OWLFieldZoomLevel = 27,
  OWLFieldScript = 28,
  OWLFieldSuccess = 29,
  OWLFieldJSON = 30,
  OWLFieldPNG = 31,
  OWLFieldText = 32,
  OWLFieldForward = 33,
  OWLFieldMatchCase = 34,
  OWLFieldFindNext = 35,
  OWLFieldMethod = 36,
  OWLFieldInputOrigin = 37,
  OWLFieldMouseKind = 38,
  OWLFieldX = 39,
  OWLFieldY = 40,
  OWLFieldButton = 41,
  OWLFieldClickCount = 42,
  OWLFieldModifiers = 43,
  OWLFieldDeltaX = 44,
  OWLFieldDeltaY = 45,
  OWLFieldKeyKind = 46,
  OWLFieldNativeKeyCode = 47,
  OWLFieldCharacter = 48,
  OWLFieldUnmodifiedCharacter = 49,
  OWLFieldTitle = 50,
  OWLFieldIsLoading = 51,
  OWLFieldCanGoBack = 52,
  OWLFieldCanGoForward = 53,
  OWLFieldProgress = 54,
  OWLFieldStatus = 55,
  OWLFieldCursor = 56,
  OWLFieldLayer = 57,
  OWLFieldSequence = 58,
  OWLFieldPixelWidth = 59,
  OWLFieldPixelHeight = 60,
  OWLFieldContextID = 61,
  OWLFieldFeature = 62,
  OWLFieldCount = 63,
  OWLFieldActiveMatch = 64,
  OWLFieldFinalUpdate = 65,
  OWLFieldHostTimestampNanos = 66,
  OWLFieldSurfaceIndex = 67,
  OWLFieldScreenX = 68,
  OWLFieldScreenY = 69,
  OWLFieldDisableSandbox = 70,
  OWLFieldHostBlitNanos = 71,
  OWLFieldDroppedFrames = 72,
  OWLFieldPresentedNanos = 73,
  // 1.1: projected browser UI. See DESIGN.md, "Browser UI over the channel".
  OWLFieldPromptID = 74,
  OWLFieldDialogKind = 75,
  OWLFieldDefaultText = 76,
  OWLFieldOrigin = 77,
  OWLFieldIsReload = 78,
  OWLFieldPermissions = 79,
  OWLFieldPermissionResult = 80,
  OWLFieldFileChooserMode = 81,
  OWLFieldAcceptTypes = 82,
  OWLFieldPaths = 83,
  OWLFieldDownloadID = 84,
  OWLFieldReceivedBytes = 85,
  OWLFieldTotalBytes = 86,
  OWLFieldDownloadState = 87,
  OWLFieldSuggestedName = 88,
  OWLFieldMimeType = 89,
  OWLFieldPath = 90,
  OWLFieldMenuItems = 91,
  OWLFieldMenuParams = 92,
  OWLFieldCommandID = 93,
  OWLFieldHost = 94,
  OWLFieldPort = 95,
  OWLFieldRealm = 96,
  OWLFieldScheme = 97,
  OWLFieldIsProxy = 98,
  OWLFieldUsername = 99,
  OWLFieldPassword = 100,
  OWLFieldCertSubject = 101,
  OWLFieldCertIssuer = 102,
  OWLFieldCertValidStart = 103,
  OWLFieldCertValidExpiry = 104,
  OWLFieldOverridable = 105,
  OWLFieldOpenerID = 106,
  OWLFieldDisposition = 107,
  OWLFieldUserGesture = 108,
  OWLFieldFrameName = 109,
  OWLFieldPopupPolicy = 110,
  OWLFieldRules = 111,
  OWLFieldRangeStart = 112,
  OWLFieldRangeEnd = 113,
  OWLFieldReplaceStart = 114,
  OWLFieldReplaceEnd = 115,
  OWLFieldRects = 116,
  OWLFieldKeepSelection = 117,
  OWLFieldCursorPosition = 118,
  OWLFieldDragOperations = 119,
  OWLFieldDragData = 120,
  OWLFieldImage = 121,
  OWLFieldColor = 122,
  OWLFieldDownloadCommand = 123,
  OWLFieldAgentInput = 124,
  // 1.2: browsing state. See DESIGN.md, "Browsing state (protocol 1.2)".
  OWLFieldMuted = 125,
  OWLFieldAudible = 126,
  OWLFieldIgnoreCache = 127,
};

/// Structured 1.1 fields are UTF-8 JSON strings, because the TLV encoding has no lists:
/// - Paths: `["/abs/path", ...]`.
/// - AcceptTypes: `[{"filter": "image/*", "extensions": ["png"], "description": ""}, ...]`.
/// - MenuItems: `[{"id": 100, "label": "Copy", "kind": "command"|"check"|"radio"|"separator"|
///   "submenu", "enabled": true, "checked": false, "items": [...]}, ...]`.
/// - MenuParams: `{"x", "y", "linkURL", "sourceURL", "pageURL", "frameURL", "selectionText",
///   "isEditable", "mediaType", "editFlags", "agent"}`.
/// - Rules: `{"schemes": ["https"], "allow": ["example.com"], "deny": [".internal"],
///   "blockPrivateAddresses": true, "allowLoopback": false}`. A host pattern matches that host and
///   its subdomains; deny wins over allow; an empty allow list allows every other host.
/// - Rects: `[[x, y, width, height], ...]` in view points, top-left origin.
/// - DragData: `{"text", "html", "url", "urlTitle", "fileName", "paths": [...]}`, every key
///   optional.
///
/// 1.2 JSON fields (in OWLFieldJSON):
/// - FaviconURLChanged: `["https://example.com/favicon.ico", ...]`, best first.
/// - NavigationHistory: `{"index": 1, "entries": [{"url": "...", "title": "..."}, ...]}`, the
///   view's whole back/forward list; `index` is the current entry.

/// Message kinds. "C->H" is client to host, "H->C" host to client. `target` in the envelope is
/// the profile or view ID the message addresses (0 for session messages). `request` pairs a
/// request with its reply (0 when there is no reply).
typedef CF_ENUM(uint16_t, OWLMessageKind) {
  // Session.
  OWLMessageKindHello = 1,           // H->C ProtocolMajor ProtocolMinor Token HostPID CEFVersion
                                     //      ChromiumVersion; port: host receive right (send)
  OWLMessageKindHelloAck = 2,        // C->H Accepted Reason? RootCachePath Locale?
                                     //      RemoteDebuggingPort UseMockKeychain KeychainService?
                                     //      RenderMode DisableSandbox ProtocolMinor (1.1; absent
                                     //      means 0)
  OWLMessageKindReady = 3,           // H->C ElapsedMilliseconds RenderMode
  OWLMessageKindInitFailed = 4,      // H->C Reason
  OWLMessageKindPing = 5,            // C->H (request)
  OWLMessageKindPong = 6,            // H->C (reply)
  OWLMessageKindShutdown = 7,        // C->H
  OWLMessageKindHostError = 8,       // H->C ErrorCode Message (target: profile/view or 0)

  // Profiles (target: profile ID).
  OWLMessageKindProfileCreate = 20,  // C->H StorageKey Persistent
  OWLMessageKindProfileDestroy = 21, // C->H

  // Views (target: view ID).
  OWLMessageKindViewCreate = 30,     // C->H ProfileID URL Width Height Scale Visible
                                     //      PopupPolicy? Rules? (1.1, applied before the first
                                     //      navigation)
  OWLMessageKindViewClose = 31,      // C->H
  OWLMessageKindViewResize = 32,     // C->H Width Height Scale ScreenX ScreenY
  OWLMessageKindViewVisibility = 33, // C->H Visible
  OWLMessageKindViewFocus = 34,      // C->H Focused
  OWLMessageKindNavigate = 35,       // C->H URL
  OWLMessageKindGoBack = 36,         // C->H
  OWLMessageKindGoForward = 37,      // C->H
  OWLMessageKindReload = 38,         // C->H IgnoreCache? (1.2; older hosts reload normally)
  OWLMessageKindStop = 39,           // C->H
  OWLMessageKindSetZoom = 40,        // C->H ZoomLevel
  OWLMessageKindEvaluate = 41,       // C->H Script (request) -> EvaluateResult
  OWLMessageKindSnapshot = 42,       // C->H (request) -> SnapshotResult
  OWLMessageKindFind = 43,           // C->H Text Forward MatchCase FindNext
  OWLMessageKindStopFind = 44,       // C->H
  OWLMessageKindShowDevTools = 45,   // C->H
  OWLMessageKindDevToolsMethod = 46, // C->H Method JSON (request) -> DevToolsResult
  OWLMessageKindInputMouse = 50,     // C->H InputOrigin MouseKind X Y Button ClickCount
                                     //      Modifiers DeltaX DeltaY
  OWLMessageKindInputKey = 51,       // C->H InputOrigin KeyKind NativeKeyCode Modifiers
                                     //      Character UnmodifiedCharacter
  OWLMessageKindFrameAck = 53,       // C->H SurfaceIndex Sequence

  // View events (target: view ID).
  OWLMessageKindViewCreated = 60,    // H->C
  OWLMessageKindURLChanged = 61,     // H->C URL
  OWLMessageKindTitleChanged = 62,   // H->C Title
  OWLMessageKindLoadingState = 63,   // H->C IsLoading CanGoBack CanGoForward
  OWLMessageKindLoadProgress = 64,   // H->C Progress
  OWLMessageKindLoadError = 65,      // H->C ErrorCode Text URL
  OWLMessageKindRendererGone = 66,   // H->C Status ErrorCode Message
  OWLMessageKindDownloadBlocked = 67,// H->C URL
  OWLMessageKindViewClosed = 68,     // H->C
  OWLMessageKindCursorChanged = 69,  // H->C Cursor
  OWLMessageKindEvaluateResult = 70, // H->C Success JSON (reply)
  OWLMessageKindSnapshotResult = 71, // H->C Success PNG? Message? (reply)
  OWLMessageKindFindResult = 72,     // H->C Count ActiveMatch FinalUpdate
  OWLMessageKindDevToolsResult = 73, // H->C Success JSON (reply)
  OWLMessageKindFrame = 74,          // H->C Layer Sequence SurfaceIndex PixelWidth PixelHeight
                                     //      Scale X Y Width Height HostTimestampNanos
                                     //      HostBlitNanos DroppedFrames; port: IOSurface
  OWLMessageKindPopupVisibility = 75,// H->C Visible
  OWLMessageKindLayerContext = 77,   // H->C ContextID
  OWLMessageKindKeyUnhandled = 78,   // H->C KeyKind NativeKeyCode Modifiers Character
                                     //      UnmodifiedCharacter
  OWLMessageKindFeatureBlocked = 79, // H->C Feature Message
  OWLMessageKindPresented = 80,      // H->C Sequence HostTimestampNanos PresentedNanos
                                     //      HostBlitNanos (remote-layer timing)

  // 1.1, client to host (target: view ID). Sent only to hosts that advertise
  // OWL_PROTOCOL_MINOR_PROMPTS. Replies name the PromptID of the host request they answer.
  OWLMessageKindSetPopupPolicy = 81,     // C->H PopupPolicy
  OWLMessageKindSetNavigationRules = 82, // C->H Rules? (JSON OWL navigation rules; absent clears)
  OWLMessageKindDialogReply = 83,        // C->H PromptID Accepted Text?
  OWLMessageKindPermissionReply = 84,    // C->H PromptID PermissionResult Permissions
  OWLMessageKindFileChooserReply = 85,   // C->H PromptID Accepted Paths?
  OWLMessageKindDownloadReply = 86,      // C->H PromptID Accepted Path?
  OWLMessageKindDownloadControl = 87,    // C->H DownloadID DownloadCommand
  OWLMessageKindContextMenuReply = 88,   // C->H PromptID CommandID (-1 dismisses)
  OWLMessageKindAuthReply = 89,          // C->H PromptID Accepted Username? Password?
  OWLMessageKindCertificateReply = 90,   // C->H PromptID Accepted
  OWLMessageKindImeSetComposition = 91,  // C->H Text RangeStart RangeEnd ReplaceStart? ReplaceEnd?
  OWLMessageKindImeCommitText = 92,      // C->H Text ReplaceStart? ReplaceEnd? CursorPosition
                                         //      AgentInput?
  OWLMessageKindImeFinishComposing = 93, // C->H KeepSelection
  OWLMessageKindImeCancelComposition = 94, // C->H
  OWLMessageKindDragEnter = 95,          // C->H X Y Modifiers DragOperations DragData
  OWLMessageKindDragOver = 96,           // C->H X Y Modifiers DragOperations
  OWLMessageKindDragLeave = 97,          // C->H
  OWLMessageKindDragDrop = 98,           // C->H X Y Modifiers
  OWLMessageKindDragSourceEnded = 99,    // C->H X Y DragOperations
  OWLMessageKindColorReply = 100,        // C->H PromptID Accepted Color?

  // 1.2, client to host (target: view ID). Sent only to hosts that advertise
  // OWL_PROTOCOL_MINOR_BROWSING.
  OWLMessageKindSetAudioMuted = 101,     // C->H Muted

  // 1.1, host to client (target: view ID; PopupCreated targets the new view).
  OWLMessageKindJSDialog = 110,          // H->C PromptID DialogKind Origin Message DefaultText?
                                         //      IsReload?
  OWLMessageKindPermissionRequest = 111, // H->C PromptID Origin Permissions
  OWLMessageKindFileChooser = 112,       // H->C PromptID FileChooserMode Title? DefaultText?
                                         //      AcceptTypes
  OWLMessageKindDownloadRequest = 113,   // H->C PromptID DownloadID URL SuggestedName MimeType?
                                         //      TotalBytes
  OWLMessageKindDownloadUpdated = 114,   // H->C DownloadID URL ReceivedBytes TotalBytes
                                         //      DownloadState Path?
  OWLMessageKindContextMenu = 115,       // H->C PromptID X Y MenuItems MenuParams
  OWLMessageKindAuthRequest = 116,       // H->C PromptID Origin Host Port Realm? Scheme? IsProxy
  OWLMessageKindCertificateError = 117,  // H->C PromptID URL ErrorCode Message CertSubject?
                                         //      CertIssuer? CertValidStart? CertValidExpiry?
                                         //      Overridable
  OWLMessageKindPromptCancelled = 118,   // H->C PromptID Reason
  OWLMessageKindPopupCreated = 119,      // H->C OpenerID URL Disposition UserGesture FrameName?
                                         //      Width? Height?
  OWLMessageKindPopupBlocked = 120,      // H->C URL Disposition UserGesture Reason
  OWLMessageKindNavigationBlocked = 121, // H->C URL Reason
  OWLMessageKindImeCompositionChanged = 122, // H->C RangeStart RangeEnd Rects
  OWLMessageKindStartDrag = 123,         // H->C DragOperations X Y DragData Image?
  OWLMessageKindDragCursor = 124,        // H->C DragOperations
  OWLMessageKindColorChooser = 125,      // H->C PromptID Color
  OWLMessageKindTextSelectionChanged = 126, // H->C Text RangeStart RangeEnd

  // 1.2, host to client (target: view ID). Sent only to clients that advertise
  // OWL_PROTOCOL_MINOR_BROWSING.
  OWLMessageKindFaviconURLChanged = 127, // H->C JSON (URL list)
  OWLMessageKindNavigationHistory = 128, // H->C JSON (entries and current index)
  OWLMessageKindAudioStateChanged = 129, // H->C Audible Muted

  // 1.3, host to client (target: view ID). Sent only to clients that advertise
  // OWL_PROTOCOL_MINOR_SIGN_IN.
  OWLMessageKindExternalProtocol = 130,  // H->C URL Origin? (a navigation to a scheme Chromium
                                         //      does not handle; the client may open it with
                                         //      the OS, the host never does)
};

/// How the host delivers pixels. See DESIGN.md, "Rendering".
typedef CF_ENUM(uint64_t, OWLRenderMode) {
  /// The host draws into its own CAContext; the client embeds it with CALayerHost.
  OWLRenderModeRemoteLayer = 1,
  /// The host sends IOSurface Mach ports per frame; the client sets them as layer contents.
  OWLRenderModeIOSurface = 2,
};

/// Values of OWLFieldLayer.
typedef CF_ENUM(uint64_t, OWLLayer) {
  OWLLayerPage = 0,
  OWLLayerPopup = 1,
};

/// Values of OWLFieldInputOrigin. Agent input is never re-dispatched to the app and never reaches
/// browser-level handlers. See DESIGN.md, "Agent input".
typedef CF_ENUM(uint64_t, OWLInputOrigin) {
  OWLInputOriginUser = 1,
  OWLInputOriginAgent = 2,
};

/// Values of OWLFieldMouseKind.
typedef CF_ENUM(uint64_t, OWLMouseKind) {
  OWLMouseKindMove = 1,
  OWLMouseKindDown = 2,
  OWLMouseKindUp = 3,
  OWLMouseKindWheel = 4,
  OWLMouseKindLeave = 5,
};

/// Values of OWLFieldButton. Match cef_mouse_button_type_t.
typedef CF_ENUM(uint64_t, OWLMouseButton) {
  OWLMouseButtonLeft = 0,
  OWLMouseButtonMiddle = 1,
  OWLMouseButtonRight = 2,
};

/// Values of OWLFieldKeyKind. Match cef_key_event_type_t.
typedef CF_ENUM(uint64_t, OWLKeyKind) {
  OWLKeyKindRawKeyDown = 0,
  OWLKeyKindKeyDown = 1,
  OWLKeyKindKeyUp = 2,
  OWLKeyKindChar = 3,
};

/// Bits of OWLFieldModifiers. Match cef_event_flags_t.
typedef CF_OPTIONS(uint64_t, OWLModifiers) {
  OWLModifierCapsLock = 1 << 0,
  OWLModifierShift = 1 << 1,
  OWLModifierControl = 1 << 2,
  OWLModifierAlt = 1 << 3,
  OWLModifierLeftMouse = 1 << 4,
  OWLModifierMiddleMouse = 1 << 5,
  OWLModifierRightMouse = 1 << 6,
  OWLModifierCommand = 1 << 7,
  OWLModifierNumLock = 1 << 8,
  OWLModifierIsKeyPad = 1 << 9,
  OWLModifierIsLeft = 1 << 10,
  OWLModifierIsRight = 1 << 11,
  OWLModifierAltGr = 1 << 12,
  OWLModifierIsRepeat = 1 << 13,
};

/// Values of OWLFieldCursor. A subset of cef_cursor_type_t the client maps to NSCursor.
typedef CF_ENUM(uint64_t, OWLCursor) {
  OWLCursorPointer = 0,
  OWLCursorCross = 1,
  OWLCursorHand = 2,
  OWLCursorIBeam = 3,
  OWLCursorWait = 4,
  OWLCursorHelp = 5,
  OWLCursorResizeEastWest = 6,
  OWLCursorResizeNorthSouth = 7,
  OWLCursorNotAllowed = 8,
  OWLCursorGrab = 9,
  OWLCursorGrabbing = 10,
  OWLCursorNone = 11,
};

/// Values of OWLFieldErrorCode in HostError.
typedef CF_ENUM(uint64_t, OWLHostErrorCode) {
  OWLHostErrorUnknownMessage = 1,
  OWLHostErrorMalformedMessage = 2,
  OWLHostErrorUnknownProfile = 3,
  OWLHostErrorUnknownView = 4,
  OWLHostErrorProfileCreateFailed = 5,
  OWLHostErrorViewCreateFailed = 6,
  OWLHostErrorRenderFailed = 7,
  OWLHostErrorDevToolsFailed = 8,
  // 1.1.
  OWLHostErrorUnknownPrompt = 9,
  OWLHostErrorPopupFailed = 10,
};

// MARK: 1.1 value sets

/// Values of OWLFieldDialogKind.
typedef CF_ENUM(uint64_t, OWLDialogKind) {
  OWLDialogKindAlert = 1,
  OWLDialogKindConfirm = 2,
  OWLDialogKindPrompt = 3,
  OWLDialogKindBeforeUnload = 4,
};

/// Bits of OWLFieldPermissions. Engine-neutral; the host maps Chromium's request types onto them.
typedef CF_OPTIONS(uint64_t, OWLPermission) {
  OWLPermissionCamera = 1 << 0,
  OWLPermissionMicrophone = 1 << 1,
  OWLPermissionGeolocation = 1 << 2,
  OWLPermissionNotifications = 1 << 3,
  OWLPermissionClipboard = 1 << 4,
  OWLPermissionScreenCapture = 1 << 5,
  OWLPermissionMIDI = 1 << 6,
  /// 1.3: requests to loopback or private-network addresses (Chromium's Local Network Access).
  OWLPermissionLocalNetwork = 1 << 7,
  /// Any request type without its own bit. Clients deny it.
  OWLPermissionOther = 1 << 30,
};

/// Values of OWLFieldPermissionResult.
typedef CF_ENUM(uint64_t, OWLPermissionResult) {
  OWLPermissionResultAllow = 1,
  OWLPermissionResultDeny = 2,
  OWLPermissionResultDismiss = 3,
};

/// Values of OWLFieldFileChooserMode. Match cef_file_dialog_mode_t.
typedef CF_ENUM(uint64_t, OWLFileChooserMode) {
  OWLFileChooserModeOpen = 0,
  OWLFileChooserModeOpenMultiple = 1,
  OWLFileChooserModeOpenFolder = 2,
  OWLFileChooserModeSave = 3,
};

/// Values of OWLFieldDownloadState.
typedef CF_ENUM(uint64_t, OWLDownloadState) {
  OWLDownloadStateInProgress = 1,
  OWLDownloadStateComplete = 2,
  OWLDownloadStateCancelled = 3,
  OWLDownloadStateInterrupted = 4,
  OWLDownloadStatePaused = 5,
};

/// Values of OWLFieldDownloadCommand.
typedef CF_ENUM(uint64_t, OWLDownloadCommand) {
  OWLDownloadCommandCancel = 1,
  OWLDownloadCommandPause = 2,
  OWLDownloadCommandResume = 3,
};

/// Values of OWLFieldDisposition. Where a page asked a new browsing context to open.
typedef CF_ENUM(uint64_t, OWLDisposition) {
  OWLDispositionCurrentTab = 1,
  OWLDispositionForegroundTab = 2,
  OWLDispositionBackgroundTab = 3,
  OWLDispositionPopup = 4,
  OWLDispositionWindow = 5,
};

/// Values of OWLFieldPopupPolicy. The host applies it synchronously when a page opens a window.
typedef CF_ENUM(uint64_t, OWLPopupPolicy) {
  /// Every window.open and target=_blank opens a new view.
  OWLPopupPolicyAllow = 1,
  /// Only opens that follow a user gesture are allowed; others are reported as blocked. Default.
  OWLPopupPolicyRequireGesture = 2,
  /// Every open is reported as blocked.
  OWLPopupPolicyBlock = 3,
};

/// Bits of OWLFieldDragOperations. Match cef_drag_operations_mask_t.
typedef CF_OPTIONS(uint64_t, OWLDragOperation) {
  OWLDragOperationCopy = 1,
  OWLDragOperationLink = 2,
  OWLDragOperationGeneric = 4,
  OWLDragOperationPrivate = 8,
  OWLDragOperationMove = 16,
  OWLDragOperationDelete = 32,
};
