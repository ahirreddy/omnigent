"""Chrome DevTools MCP for session agents, scoped to the session's browser tabs.

The runner launches Google's ``chrome-devtools-mcp`` per session and points it at
:class:`~omnigent.runner.browser_devtools.server.BrowserDevtoolsService`, a loopback
CDP proxy that presents a virtual browser holding only that session's tabs. The
design is in ``apps/apple/docs/agent-browser-mcp-design.md``.
"""
