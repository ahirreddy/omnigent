"""Give a session's agent Chrome DevTools MCP in place of the ``browser_*`` tools.

The server turns the feature on per bundle download (``X-Omnigent-Browser-Devtools``);
the runner then adds a per-session stdio MCP server that runs Google's
``chrome-devtools-mcp`` against the runner's scoped CDP proxy.
"""

from __future__ import annotations

from dataclasses import replace
from typing import Final

from omnigent.spec.types import AgentSpec, MCPServerConfig

BROWSER_DEVTOOLS_HEADER: Final[str] = "X-Omnigent-Browser-Devtools"
BROWSER_DEVTOOLS_SERVER_NAME: Final[str] = "chrome_devtools"
# Published 2026-10-22: older than the dependency cooldown, so package mirrors
# that embargo new releases already serve it.
CHROME_DEVTOOLS_MCP_PACKAGE: Final[str] = "chrome-devtools-mcp@1.12.0"
# Performance traces can take minutes.
BROWSER_DEVTOOLS_TOOL_TIMEOUT_S: Final[int] = 180
# Marks the injected server, so an author's own ``chrome_devtools`` entry is told apart.
BROWSER_DEVTOOLS_MARKER_ENV: Final[str] = "OMNIGENT_BROWSER_DEVTOOLS"


def browser_devtools_server(endpoint: str) -> MCPServerConfig:
    """The stdio MCP server that runs ``chrome-devtools-mcp`` against *endpoint*.

    :param endpoint: The session's proxy URL, e.g.
        ``"ws://127.0.0.1:52341/devtools/browser/conv_abc.1f2e"``.
    :returns: The server config; ``npx`` resolves the package through the
        runner's npm registry setting.
    """
    return MCPServerConfig(
        name=BROWSER_DEVTOOLS_SERVER_NAME,
        transport="stdio",
        command="npx",
        args=[
            "-y",
            CHROME_DEVTOOLS_MCP_PACKAGE,
            "--wsEndpoint",
            endpoint,
            "--no-usage-statistics",
            "--no-performance-crux",
        ],
        env={
            BROWSER_DEVTOOLS_MARKER_ENV: "1",
            "CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS": "1",
            "CHROME_DEVTOOLS_MCP_NO_CONFIG_DISCOVERY": "1",
            "CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS": "1",
        },
        description="Chrome DevTools for the session's browser tabs",
        timeout=BROWSER_DEVTOOLS_TOOL_TIMEOUT_S,
    )


def with_browser_devtools(spec: AgentSpec, endpoint: str) -> AgentSpec:
    """Return *spec* and its sub-agents with DevTools MCP in place of ``browser_*``.

    An agent that turned the browser tool group off, or that declares its own
    ``chrome_devtools`` server, is left unchanged.

    :param spec: A session's freshly resolved spec (never a shared cached one).
    :param endpoint: The session's proxy URL.
    """
    sub_agents = [with_browser_devtools(child, endpoint) for child in spec.sub_agents]
    declared = any(server.name == BROWSER_DEVTOOLS_SERVER_NAME for server in spec.mcp_servers)
    if not spec.tool_groups.browser or declared:
        return replace(spec, sub_agents=sub_agents)
    return replace(
        spec,
        mcp_servers=[*spec.mcp_servers, browser_devtools_server(endpoint)],
        tool_groups=replace(spec.tool_groups, browser=False),
        sub_agents=sub_agents,
    )


def has_browser_devtools(spec: AgentSpec) -> bool:
    """Whether the runner gave *spec* the scoped DevTools MCP server."""
    return any(
        server.name == BROWSER_DEVTOOLS_SERVER_NAME
        and server.env.get(BROWSER_DEVTOOLS_MARKER_ENV) == "1"
        for server in spec.mcp_servers
    )
