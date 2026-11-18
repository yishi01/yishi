"""Tool schemas, prompt template, and permission/retry constants for DeepSeek agents."""

from __future__ import annotations

from typing import Any

WRITE_TOOLS = {"write_file", "edit_file", "run_command", "run_plugin"}
COMMAND_TOOLS = {"run_command", "run_plugin"}
SUBAGENT_ORCHESTRATION_TOOLS = {"spawn_agents", "wait_agents", "message_agent", "cancel_agent"}
META_EVENT_TYPES = {"status", "turn_deleted", "turns_truncated", "queue_updated"}
MAX_TOOL_ROUNDS = 24
RETRYABLE_STATUS_CODES = {408, 409, 425, 429, 500, 502, 503, 504}

SYSTEM_PROMPT = """You are a skilled AI coding assistant running inside the user's Windows workspace via DeepSeek Mobile Bridge.
You have tools to inspect directories, read files, search code, write/edit files, present files to the user for download/review (Claude Artifact style), inspect git status/diff, run shell commands, capture PC screenshots, browse web pages collaboratively, read sibling workspace sessions, spawn parallel sub-agents, and ask the user questions.

Environment Facts:
- Bridge HTTP/WebSocket server: http://127.0.0.1:8765 (health checks: http://127.0.0.1:8765/health and http://127.0.0.1:8765/api/health)
- Project Python virtualenv: .venv\\Scripts\\python.exe (automatically prepended to PATH in run_command)
- Frontend in `web/` is zero-build native ES Modules (no Node.js / npm required)
- Active workspace root: {workspace}
- AI Access Isolation Mode: {ai_access_mode} (Allowed workspaces: {allowed_workspaces})

Guidelines:
- Always inspect relevant files before editing them.
- Prefer `edit_file` for targeted changes to existing files and `write_file` for creating new files.
- Whenever the user asks you to send/share/provide a file for download, OR asks to review a newly created or modified file, call `present_file` so a Claude-style interactive File Artifact & Download card is pushed directly to their phone screen.
- Whenever the user asks to take a screenshot, see the PC screen/desktop/window, or check what is on the computer screen, immediately call `take_screenshot` (target='full', 'window', or 'region'). It will automatically push an interactive Image Artifact Card with live image preview & download to their phone screen.
- Keep responses concise and clear for mobile reading.
"""

TOOL_SCHEMAS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "list_directory",
            "description": "List files and subdirectories inside the workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Relative path from workspace root (empty string for root).",
                    }
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read a text file inside the workspace with optional line range.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Relative path to the file."},
                    "start_line": {"type": "integer", "description": "1-based start line (optional)."},
                    "end_line": {"type": "integer", "description": "1-based inclusive end line (optional)."},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Create or overwrite a text file inside the workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Relative path to the file."},
                    "content": {"type": "string", "description": "Full file contents."},
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "edit_file",
            "description": "Replace an exact target text block inside an existing workspace file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Relative path to the file."},
                    "target": {"type": "string", "description": "Exact existing text to replace."},
                    "replacement": {"type": "string", "description": "New replacement text."},
                },
                "required": ["path", "target", "replacement"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_files",
            "description": "Search filenames and text contents in the workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query string."},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "git_status_diff",
            "description": "Show git branch, modified files, and unified diff in the workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Optional relative file path filter."},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_command",
            "description": "Execute a PowerShell command in the workspace directory.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "PowerShell command to execute."},
                    "timeout": {"type": "integer", "description": "Timeout in seconds (default 60)."},
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "present_file",
            "description": "Send or present a file to the user on their mobile screen as a Claude-style File Artifact card for immediate review, preview, or local download.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Relative or absolute path to the file on the PC.",
                    },
                    "title": {
                        "type": "string",
                        "description": "Display title for the file card (optional).",
                    },
                    "summary": {
                        "type": "string",
                        "description": "Brief summary of what this file contains or what was changed (optional).",
                    },
                    "mode": {
                        "type": "string",
                        "enum": ["review", "download"],
                        "description": "'review' for newly created/modified files to inspect, or 'download' when the user asked to download a file.",
                    },
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "ask_user",
            "description": "Ask the user a clarifying question on their mobile screen and wait for their answer.",
            "parameters": {
                "type": "object",
                "properties": {
                    "question": {"type": "string", "description": "The question to ask."},
                    "options": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional list of quick-reply options.",
                    },
                },
                "required": ["question"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Search the public web using the configured search provider (DuckDuckGo, Tavily, Brave, Serper, Bocha, or Custom).",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query keywords."},
                    "max_results": {"type": "integer", "description": "Max search results (1-10)."},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_plugins",
            "description": "List installed PC DSH plugins, enabled skills, and executable plugin tools.",
            "parameters": {
                "type": "object",
                "properties": {},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_plugin",
            "description": "Execute a tool provided by an enabled PC DSH plugin on the host PC.",
            "parameters": {
                "type": "object",
                "properties": {
                    "plugin_id": {"type": "string", "description": "Plugin ID from list_plugins."},
                    "tool_name": {"type": "string", "description": "Tool name inside the plugin (optional if default)."},
                    "args": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "CLI arguments to pass to the PC plugin script.",
                    },
                    "stdin_text": {"type": "string", "description": "Optional stdin string."},
                },
                "required": ["plugin_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "sandbox_audit_run",
            "description": "Perform static security self-check and optionally run untrusted code in an isolated PC sandbox without host secrets.",
            "parameters": {
                "type": "object",
                "properties": {
                    "code": {"type": "string", "description": "Source code to inspect or simulate."},
                    "language": {
                        "type": "string",
                        "enum": ["python", "javascript", "powershell", "bash", "html"],
                        "description": "Script language.",
                    },
                    "execute": {
                        "type": "boolean",
                        "description": "True to execute inside isolated PC sandbox after audit; false for static security audit only.",
                    },
                    "allow_network": {
                        "type": "boolean",
                        "description": "Allow outbound network in simulator (default false).",
                    },
                },
                "required": ["code", "language"],
            },
        },
    },
    # Module A: Cross-Session Reading Tools
    {
        "type": "function",
        "function": {
            "name": "list_workspace_sessions",
            "description": "List other conversation sessions in the SAME Workspace Profile.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Optional keyword filter for session title or messages."},
                    "limit": {"type": "integer", "description": "Max sessions to return (default 20)."},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_session_transcript",
            "description": "Read user and assistant dialogue turns from another session in the SAME Workspace Profile.",
            "parameters": {
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "Target session_id to read."},
                    "turn_range": {
                        "type": "array",
                        "items": {"type": "integer"},
                        "description": "Optional [start_idx, end_idx] turn range.",
                    },
                    "search": {"type": "string", "description": "Optional keyword filter within turns."},
                    "max_chars": {"type": "integer", "description": "Max characters to return (default 12000)."},
                },
                "required": ["session_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_session_artifacts",
            "description": "List file artifacts and touched file paths from another session in the SAME Workspace Profile.",
            "parameters": {
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "Target session_id to inspect."},
                },
                "required": ["session_id"],
            },
        },
    },
    # Module B: Native PC Screenshot Tool
    {
        "type": "function",
        "function": {
            "name": "take_screenshot",
            "description": "Capture a screenshot of the host PC screen, a specific window, or a screen region.",
            "parameters": {
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "enum": ["full", "window", "region"],
                        "description": "Capture target mode: 'full', 'window', or 'region'.",
                    },
                    "window_title": {
                        "type": "string",
                        "description": "Window title substring when target='window'.",
                    },
                    "region": {
                        "type": "array",
                        "items": {"type": "integer"},
                        "description": "[x, y, width, height] when target='region'.",
                    },
                },
                "required": [],
            },
        },
    },
    # Module F: Collaborative Browser Tools
    {
        "type": "function",
        "function": {
            "name": "browser_open",
            "description": "Open a URL in the collaborative session browser and render an interactive viewport card in chat.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "Target HTTP/HTTPS URL to open."},
                },
                "required": ["url"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "browser_snapshot",
            "description": "Get the current browser page title, URL, numbered interactive elements, and viewport snapshot.",
            "parameters": {
                "type": "object",
                "properties": {},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "browser_click",
            "description": "Click an interactive element by its numbered badge [element_id] or viewport coordinates (x, y).",
            "parameters": {
                "type": "object",
                "properties": {
                    "element_id": {"type": "integer", "description": "Numbered element ID from browser snapshot."},
                    "x": {"type": "integer", "description": "Viewport X coordinate (optional)."},
                    "y": {"type": "integer", "description": "Viewport Y coordinate (optional)."},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "browser_type",
            "description": "Type text into an input/textarea element in the collaborative browser.",
            "parameters": {
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "Text to type."},
                    "element_id": {"type": "integer", "description": "Target input element ID (optional)."},
                    "submit": {"type": "boolean", "description": "True to submit the form after typing."},
                },
                "required": ["text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "browser_scroll",
            "description": "Scroll the collaborative browser viewport vertically.",
            "parameters": {
                "type": "object",
                "properties": {
                    "delta_y": {"type": "integer", "description": "Vertical scroll delta in pixels (positive=down, negative=up)."},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "browser_back",
            "description": "Navigate back to the previous page in the collaborative browser history.",
            "parameters": {
                "type": "object",
                "properties": {},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "browser_extract",
            "description": "Extract clean Markdown text and interactive elements list from the current browser page.",
            "parameters": {
                "type": "object",
                "properties": {},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "browser_screenshot",
            "description": "Save the current browser viewport frame as an image attachment.",
            "parameters": {
                "type": "object",
                "properties": {},
            },
        },
    },
    # Module D: Sub-Agent Team Orchestration Tools
    {
        "type": "function",
        "function": {
            "name": "spawn_agents",
            "description": "Spawn up to 4 parallel sub-agents to execute subtasks concurrently.",
            "parameters": {
                "type": "object",
                "properties": {
                    "agents": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "role": {"type": "string", "description": "Sub-agent role title."},
                                "task": {"type": "string", "description": "Detailed task instructions for the sub-agent."},
                                "profile_id": {"type": "string", "description": "Optional model profile ID."},
                                "max_rounds": {"type": "integer", "description": "Max tool rounds (default 8)."},
                                "allow_writes": {"type": "boolean", "description": "Allow write/command tools (default false)."},
                            },
                            "required": ["role", "task"],
                        },
                        "description": "List of sub-agent specifications to spawn (max 4).",
                    }
                },
                "required": ["agents"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "wait_agents",
            "description": "Wait for spawned sub-agents to complete and collect their findings.",
            "parameters": {
                "type": "object",
                "properties": {
                    "agent_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Agent IDs to wait for (empty for all active sub-agents).",
                    },
                    "timeout_sec": {"type": "integer", "description": "Timeout in seconds (default 90)."},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "message_agent",
            "description": "Send a follow-up instruction to an existing sub-agent.",
            "parameters": {
                "type": "object",
                "properties": {
                    "agent_id": {"type": "string", "description": "Target sub-agent ID."},
                    "text": {"type": "string", "description": "Follow-up instruction text."},
                },
                "required": ["agent_id", "text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "cancel_agent",
            "description": "Cancel a running sub-agent.",
            "parameters": {
                "type": "object",
                "properties": {
                    "agent_id": {"type": "string", "description": "Target sub-agent ID to cancel."},
                },
                "required": ["agent_id"],
            },
        },
    },
]
