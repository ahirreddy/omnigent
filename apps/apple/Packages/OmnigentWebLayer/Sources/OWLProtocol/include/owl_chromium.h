// Chromium switches the web host's browser process runs with (OnBeforeCommandLineProcessing in
// OWLHost.mm), shared so the client's tests pin them.
#pragma once

/// Chromium features the browser process turns off:
/// - MacAppCodeSignClone: Chrome copies its bundle to a temporary "code sign clone" so in-place
///   updates cannot break running helpers, then launches a detached
///   --type=code-sign-clone-cleanup helper at exit, which CEF helpers cannot run. The host bundle
///   is immutable inside the signed app, so the clone is unnecessary.
/// - SystemNotifications: Chrome's macOS notification bridge starts with the browser, and the
///   host and its helper each asked macOS for notification permission at launch. The host
///   posts nothing through macOS; a page allowed to notify gets Chrome's own popups instead.
#define OWL_CHROMIUM_DISABLED_FEATURES "MacAppCodeSignClone,SystemNotifications"
