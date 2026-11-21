"""Schema-only ``browser_switch`` builtin for sessions with Chrome DevTools MCP.

The agent asks to move its browser between the owner's Mac (``local``) and the
agent machine's browser (``remote``), or back to ``auto``. Execution lives in the
runner (``omnigent.runner.browser_devtools.choice.switch_browser``), which needs the
runner's server client to ask the owner and write the session label.
"""

from __future__ import annotations

from typing import Any

from omnigent.tools.base import Tool

BROWSER_SWITCH_TOOL_NAME = "browser_switch"


class BrowserSwitchTool(Tool):
    """Point the session's chrome_devtools tools at another browser (schema only)."""

    @classmethod
    def name(cls) -> str:
        """:returns: ``"browser_switch"``."""
        return BROWSER_SWITCH_TOOL_NAME

    @classmethod
    def description(cls) -> str:
        """:returns: Human-readable description of the tool."""
        return (
            "Switch the browser the chrome_devtools tools drive: 'local' is the user's Mac "
            "browser with their logins (the user must approve it), 'remote' is the browser "
            "on the agent's machine, which keeps working while the Mac sleeps, and 'auto' "
            "lets Omnigent pick. The next chrome_devtools call lands in the new browser; tabs "
            "stay open in the old one, and logins and cookies don't carry over."
        )

    def get_schema(self) -> dict[str, Any]:
        """
        Return the OpenAI-format tool schema.

        :returns: Dict with ``"type": "function"`` and a ``"function"`` sub-dict.
        """
        return {
            "type": "function",
            "function": {
                "name": BROWSER_SWITCH_TOOL_NAME,
                "description": BrowserSwitchTool.description(),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "target": {
                            "type": "string",
                            "enum": ["local", "remote", "auto"],
                            "description": "The browser to use.",
                        },
                        "reason": {
                            "type": "string",
                            "description": (
                                "Why, in one sentence the user reads when asked to approve, "
                                "e.g. 'The site needs your signed-in account'."
                            ),
                        },
                    },
                    "required": ["target", "reason"],
                },
            },
        }
