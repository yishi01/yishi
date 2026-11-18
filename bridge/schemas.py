"""Pydantic request schemas and multipart upload helper for DeepSeek Mobile Bridge."""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field


class AuthVerifyRequest(BaseModel):
    token: str


class SettingsUpdateRequest(BaseModel):
    workspaces: list[str] | None = None
    active_workspace: str | None = None
    ai_access_mode: str | None = None
    default_approval_mode: str | None = None
    bark_url: str | None = None
    deepseek_base_url: str | None = None
    model: str | None = None
    deepseek_api_key: str | None = None
    enable_tunnel: bool | None = None
    cloudflared_token: str | None = None
    public_url: str | None = None
    rendezvous_gist_id: str | None = None
    tailscale_urls: list[str] | None = None
    active_profile_id: str | None = None
    model_profiles: list[dict[str, Any]] | None = None
    search_config: dict[str, Any] | None = None
    appearance_config: dict[str, Any] | None = None
    dsh_profile_dir: str | None = None
    wallet_rules: dict[str, Any] | None = None
    model_pricing: dict[str, Any] | None = None
    browser_policy: dict[str, Any] | None = None


class ProviderTestRequest(BaseModel):
    profile_id: str | None = None
    provider: str | None = None
    base_url: str | None = None
    api_key: str | None = None
    model: str | None = None
    test_vision: bool = False


class SearchTestRequest(BaseModel):
    query: str
    search_config: dict[str, Any] | None = None
    max_results: int = 5


class PluginInstallRequest(BaseModel):
    source_type: str = "inline"  # upload | local_path | git | inline
    name: str = ""
    description: str = ""
    local_path: str = ""
    git_url: str = ""
    branch: str = ""
    filename: str = ""
    content_base64: str = ""
    skill_markdown: str = ""
    script_code: str = ""
    script_language: str = "python"
    config: dict[str, Any] | None = None
    env: dict[str, str] | None = None


class PluginToggleRequest(BaseModel):
    enabled: bool


class PluginConfigUpdateRequest(BaseModel):
    config: dict[str, Any] | None = None
    env: dict[str, str] | None = None
    enabled: bool | None = None


class PluginRunRequest(BaseModel):
    tool_name: str = ""
    args: list[str] = Field(default_factory=list)
    stdin_text: str = ""
    workspace: str | None = None
    timeout_sec: int = 20


class DshToggleRequest(BaseModel):
    kind: str = "bundle"  # bundle | patch
    id: str
    enabled: bool


class DshConfigRequest(BaseModel):
    entry_id: str
    config: dict[str, Any] = Field(default_factory=dict)
    enabled: bool | None = None


class DshInstallRequest(BaseModel):
    spec: str


class SandboxAuditRequest(BaseModel):
    code: str
    language: str = "python"
    filename: str = ""


class SandboxRunRequest(BaseModel):
    code: str
    language: str = "python"
    timeout_sec: int = 10
    allow_network: bool = False
    args: list[str] = Field(default_factory=list)
    stdin_text: str = ""


class AuthorizeWorkspaceRequest(BaseModel):
    path: str
    set_active: bool = True
    session_id: str | None = None


class CreateSessionRequest(BaseModel):
    workspace: str | None = None
    workspace_profile_id: str | None = None
    title: str = "New Session"
    approval_mode: str | None = None
    model: str | None = None
    profile_id: str | None = None


class RenameSessionRequest(BaseModel):
    title: str


class MoveSessionRequest(BaseModel):
    workspace_profile_id: str


class EditTurnRequest(BaseModel):
    text: str = ""
    prompt: str = ""
    model: str | None = None
    profile_id: str | None = None
    attachments: list[str] | None = None


class RegenerateTurnRequest(BaseModel):
    model: str | None = None
    profile_id: str | None = None


class SendMessageRequest(BaseModel):
    prompt: str = ""
    model: str | None = None
    profile_id: str | None = None
    attachments: list[str] | None = None
    queue_if_busy: bool = True


class PCScreenshotRequest(BaseModel):
    target: str = "full"
    window_title: str = ""
    region: list[int] | None = None
    monitor: int = 0
    session_id: str | None = None


class BrowserSessionCreateRequest(BaseModel):
    browser_id: str | None = None
    session_id: str = "global"
    workspace_profile_id: str = "ws_default"
    url: str | None = None


class BrowserNavigateRequest(BaseModel):
    url: str
    actor: Literal["agent", "human"] = "human"


class BrowserInputRequest(BaseModel):
    action: str = ""  # click | type | scroll
    element_id: int | None = None
    x: int | None = None
    y: int | None = None
    text: str | None = None
    submit: bool = False
    delta_y: int | None = None
    actor: Literal["agent", "human"] = "human"


class BrowserControlRequest(BaseModel):
    owner: Literal["agent", "human"]
    reason: str = ""


class ApprovalDecisionRequest(BaseModel):
    allow: bool
    reason: str = ""
    set_approval_mode: str | None = None


class InteractionDecisionRequest(BaseModel):
    cancelled: bool = False
    responses: list[dict[str, Any]] = Field(default_factory=list)


class WriteFileRequest(BaseModel):
    workspace: str
    path: str
    content: str
    expected_mtime: float | None = None
    force: bool = False


class CreateEntryRequest(BaseModel):
    workspace: str
    path: str
    is_dir: bool = False
    content: str = ""


class RenameEntryRequest(BaseModel):
    workspace: str
    old_path: str
    new_path: str


class PCWriteFileRequest(BaseModel):
    path: str
    content: str


class PCCreateEntryRequest(BaseModel):
    path: str
    is_dir: bool = False
    content: str = ""


class PCMoveOrCopyRequest(BaseModel):
    src_path: str
    dst_path: str
    overwrite: bool = False


def extract_multipart_file_bytes(raw_body: bytes, content_type: str) -> tuple[bytes, str]:
    """Fallback multipart/form-data extractor when python-multipart is not installed."""
    boundary = ""
    for part in content_type.split(";"):
        p = part.strip()
        if p.lower().startswith("boundary="):
            boundary = p.split("=", 1)[1].strip().strip('"')
            break
    if not boundary:
        return raw_body, "image.jpg"

    delim = f"--{boundary}".encode("latin1")
    for sec in raw_body.split(delim):
        if b"Content-Disposition" not in sec:
            continue
        header_end = sec.find(b"\r\n\r\n")
        if header_end < 0:
            continue
        header_bytes = sec[:header_end].decode("utf-8", errors="replace")
        content = sec[header_end + 4 :]
        if content.endswith(b"\r\n"):
            content = content[:-2]
        if not content:
            continue
        fname = "image.jpg"
        if 'filename="' in header_bytes:
            fname = header_bytes.split('filename="', 1)[1].split('"', 1)[0] or fname
        return content, fname
    return raw_body, "image.jpg"
