"""Which CDP methods an agent may call through the scoped proxy.

The proxy forwards ordinary page-session traffic. These tables name the
exceptions: browser-level methods it emulates or forwards, methods refused
because they reach beyond the session's tabs (the profile's cookie jar, cache,
downloads, extensions, passkeys, the browser process), and actuating methods it
refuses while the user holds the tab.
"""

from __future__ import annotations

from typing import Final

# Browser-level methods forwarded unchanged; every other browser-level method
# that the proxy does not emulate is refused.
BROWSER_FORWARDED_METHODS: Final[frozenset[str]] = frozenset(
    {
        "Browser.getVersion",
        "Target.getBrowserContexts",
    }
)

# Domains refused on every session: they act on the whole profile or process.
REFUSED_DOMAINS: Final[frozenset[str]] = frozenset(
    {"Autofill", "Extensions", "PWA", "Tethering", "WebAuthn"}
)

# Individual methods refused on every session for the same reason.
REFUSED_METHODS: Final[frozenset[str]] = frozenset(
    {
        "Browser.close",
        "Browser.crash",
        "Browser.crashGpuProcess",
        "Browser.grantPermissions",
        "Browser.resetPermissions",
        "Browser.setDownloadBehavior",
        "Browser.setPermission",
        "Network.clearBrowserCache",
        "Network.clearBrowserCookies",
        "Network.deleteCookies",
        "Network.getAllCookies",
        "Network.setCookie",
        "Network.setCookies",
        "Page.setDownloadBehavior",
        "Storage.clearCookies",
        "Storage.clearDataForOrigin",
        "Storage.clearDataForStorageKey",
        "Storage.getCookies",
        "Storage.setCookies",
        "Target.attachToBrowserTarget",
        "Target.createBrowserContext",
        "Target.disposeBrowserContext",
        "Target.exposeDevToolsProtocol",
        "Target.openDevTools",
        "Target.sendMessageToTarget",
        "Target.setRemoteLocations",
    }
)

# Methods that change what the user sees or does, refused while the user holds
# the tab. Reads (snapshots, console, network, evaluation) keep working.
ACTUATING_DOMAINS: Final[frozenset[str]] = frozenset({"Input"})
ACTUATING_METHODS: Final[frozenset[str]] = frozenset(
    {
        "Browser.setContentsSize",
        "DOM.setFileInputFiles",
        "Emulation.setCPUThrottlingRate",
        "Emulation.setDeviceMetricsOverride",
        "Emulation.setEmulatedMedia",
        "Emulation.setGeolocationOverride",
        "Emulation.setTouchEmulationEnabled",
        "Emulation.setUserAgentOverride",
        "Network.emulateNetworkConditions",
        "Network.emulateNetworkConditionsByRule",
        "Page.close",
        "Page.handleJavaScriptDialog",
        "Page.navigate",
        "Page.navigateToHistoryEntry",
        "Page.reload",
        "Page.resetNavigationHistory",
        "Target.closeTarget",
    }
)

USER_IN_CONTROL_MESSAGE: Final[str] = (
    "user_in_control: the user has taken over this tab. Do not act on it until they hand "
    "it back; wait, or call browser_request_human, then take a fresh snapshot."
)


def method_domain(method: str) -> str:
    """Return the CDP domain of *method*, e.g. ``"Input"`` for ``"Input.dispatchKeyEvent"``."""
    return method.split(".", 1)[0]


def is_refused(method: str) -> bool:
    """Whether *method* is refused on every session because it reaches beyond the tab."""
    return method in REFUSED_METHODS or method_domain(method) in REFUSED_DOMAINS


def is_actuating(method: str) -> bool:
    """Whether *method* acts on the page and must wait while the user holds the tab."""
    return method in ACTUATING_METHODS or method_domain(method) in ACTUATING_DOMAINS


def refused_message(method: str) -> str:
    """The error text for a refused *method*."""
    return (
        f"{method} is not available to agents: it reaches beyond this session's tabs "
        "(profile cookies, cache, downloads, extensions or the browser itself)."
    )
