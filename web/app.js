const TOKEN_KEY = "agy_mobile_token";
const ACTIVE_SESSION_KEY = "agy_mobile_session_id";
const ACTIVE_WS_KEY = "agy_mobile_workspace";
const ACTIVE_WS_PROFILE_KEY = "agy_mobile_ws_profile_id";
const FILTER_WS_SESSIONS_KEY = "agy_mobile_filter_ws_sessions";

const state = {
  token: localStorage.getItem(TOKEN_KEY) || "",
  settings: null,
  workspace: localStorage.getItem(ACTIVE_WS_KEY) || "",
  workspaceProfiles: [],
  activeWorkspaceProfileId: localStorage.getItem(ACTIVE_WS_PROFILE_KEY) || "ws_default",
  filterSessionsByWorkspace: localStorage.getItem(FILTER_WS_SESSIONS_KEY) === "1",
  sessions: [],
  activeSessionId: localStorage.getItem(ACTIVE_SESSION_KEY) || "",
  lastSeq: 0,
  ws: null,
  wsSynced: false,
  reconnectTimer: null,
  currentTurn: null,
  activeTurnId: "",
  scrollRaf: null,
  resolvingIds: new Set(),
  sendingPrompt: false,
  pendingAttachments: [], // [{ att_id, filename, url, thumb_url, width, height }]
  activeBrowserId: "",
  walletSummary: null,
  currentDir: "",
  openFile: null, // { path, mtime, dirty, editorType, cmView, textarea }
  cmPromise: null,
  lightboxZoom: 1,
};

const $ = (id) => document.getElementById(id);

function showToast(msg) {
  const el = $("toast");
  if (!el) return;
  el.textContent = msg;
  el.classList.remove("hidden");
  clearTimeout(showToast._t);
  showToast._t = setTimeout(() => el.classList.add("hidden"), 2600);
}

function authUrl(urlPath) {
  if (!urlPath) return "";
  if (urlPath.startsWith("data:") || urlPath.startsWith("blob:")) return urlPath;
  const sep = urlPath.includes("?") ? "&" : "?";
  return state.token ? `${urlPath}${sep}token=${encodeURIComponent(state.token)}` : urlPath;
}

async function copyText(text, msg = "已复制") {
  try {
    await navigator.clipboard.writeText(text);
    showToast(msg);
  } catch {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    try {
      document.execCommand("copy");
      showToast(msg);
    } catch {
      prompt("复制文本：", text);
    } finally {
      ta.remove();
    }
  }
}

// Delegate copy button clicks inside rendered Markdown code blocks
document.addEventListener("click", (e) => {
  const copyBtn = e.target.closest(".md-copy-btn");
  if (!copyBtn) return;
  const block = copyBtn.closest(".md-code-block");
  const codeEl = block?.querySelector("code");
  if (codeEl) {
    copyText(codeEl.textContent || "", "代码已复制");
  }
});

async function api(path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (state.token) {
    headers.set("Authorization", `Bearer ${state.token}`);
  }
  if (options.body && !(options.body instanceof FormData) && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  const resp = await fetch(path, { ...options, headers });
  if (resp.status === 401) {
    handleUnauthorized();
    throw new Error("Token 无效或已过期");
  }
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) {
    const err = new Error(data.detail || data.error || `请求失败 (HTTP ${resp.status})`);
    err.status = resp.status;
    throw err;
  }
  return data;
}

function handleUnauthorized() {
  state.token = "";
  localStorage.removeItem(TOKEN_KEY);
  if (state.ws) state.ws.close();
  $("main-view").classList.add("hidden");
  $("auth-view").classList.remove("hidden");
}

function setConnStatus(mode, label) {
  $("conn-badge").className = `status-dot ${mode}`;
  $("conn-label").textContent = label;
}

// Doubao-style Dynamic Island Capsule controller
let islandRetractTimer = null;
function setDynamicIslandState(phase) {
  const pill = $("dynamic-island-pill");
  const ico = $("island-icon");
  const txt = $("island-text");
  if (!pill || !ico || !txt) return;

  clearTimeout(islandRetractTimer);
  pill.classList.remove("retracting");

  if (!phase || phase === "idle") {
    pill.classList.add("retracting");
    islandRetractTimer = setTimeout(() => pill.classList.add("hidden"), 280);
    return;
  }

  pill.classList.remove("hidden");
  if (phase === "thinking") {
    ico.textContent = "✨";
    txt.textContent = "深度思考中...";
  } else if (phase === "tool") {
    ico.textContent = "🔧";
    txt.textContent = "工具调用中...";
  } else if (phase === "approval") {
    ico.textContent = "🔔";
    txt.textContent = "等待操作确认";
  } else if (phase === "answering") {
    ico.textContent = "💬";
    txt.textContent = "正在生成回复...";
  } else if (phase === "done") {
    ico.textContent = "✅";
    txt.textContent = "输出已完成";
    islandRetractTimer = setTimeout(() => {
      pill.classList.add("retracting");
      setTimeout(() => pill.classList.add("hidden"), 280);
    }, 2200);
  }
}

// --- Safe, Zero-Dependency Markdown Renderer ---

function normalizeCleanText(raw) {
  return String(raw || "")
    .replace(/\r\n?/g, "\n")
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, "");
}

function renderInlineMarkdown(escapedLine, inlineCodes) {
  let out = escapedLine.replace(/`([^`\n]+)`/g, (_m, code) => {
    const idx = inlineCodes.length;
    inlineCodes.push(`<code class="md-inline-code">${code}</code>`);
    return `\u0000INLINECODE_${idx}\u0000`;
  });

  out = out.replace(
    /\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g,
    '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>'
  );

  out = out.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  out = out.replace(/__([^_]+)__/g, "<strong>$1</strong>");
  out = out.replace(/(^|[\s(])\*([^*\n]+)\*(?=[\s).,!?:;]|$)/g, "$1<em>$2</em>");
  out = out.replace(/~~([^~]+)~~/g, "<del>$1</del>");

  out = out.replace(/\u0000INLINECODE_(\d+)\u0000/g, (_m, i) => inlineCodes[Number(i)] || "");
  return out;
}

function renderMarkdown(rawText) {
  const cleaned = normalizeCleanText(rawText);
  if (!cleaned.trim()) return "";

  const codeBlocks = [];
  const inlineCodes = [];

  const withCodePlaceholders = cleaned.replace(
    /```([a-zA-Z0-9_-]*)\n?([\s\S]*?)(?:```|$)/g,
    (_m, lang, code) => {
      const idx = codeBlocks.length;
      const safeLang = escapeHtml((lang || "text").trim());
      const safeCode = escapeHtml(code.replace(/\n$/, ""));
      codeBlocks.push(
        `<div class="md-code-block"><div class="md-code-head"><span>${safeLang}</span><button type="button" class="md-copy-btn">复制</button></div><pre><code>${safeCode}</code></pre></div>`
      );
      return `\n\u0000CODEBLOCK_${idx}\u0000\n`;
    }
  );

  const lines = withCodePlaceholders.split("\n");
  const htmlParts = [];
  let i = 0;

  while (i < lines.length) {
    const rawLine = lines[i];
    const trimmed = rawLine.trim();

    if (!trimmed) {
      i++;
      continue;
    }

    const cbMatch = trimmed.match(/^\u0000CODEBLOCK_(\d+)\u0000$/);
    if (cbMatch) {
      htmlParts.push(codeBlocks[Number(cbMatch[1])] || "");
      i++;
      continue;
    }

    if (/^(?:---|\*\*\*|___)\s*$/.test(trimmed)) {
      htmlParts.push("<hr />");
      i++;
      continue;
    }

    const hMatch = trimmed.match(/^(#{1,6})\s+(.+)$/);
    if (hMatch) {
      const level = Math.min(4, hMatch[1].length);
      const content = renderInlineMarkdown(escapeHtml(hMatch[2].trim()), inlineCodes);
      htmlParts.push(`<h${level}>${content}</h${level}>`);
      i++;
      continue;
    }

    if (
      trimmed.startsWith("|") &&
      trimmed.endsWith("|") &&
      i + 1 < lines.length &&
      /^\s*\|[\s:-]+\|\s*$/.test(lines[i + 1])
    ) {
      const parseRow = (rowStr) =>
        rowStr
          .trim()
          .replace(/^\||\|$/g, "")
          .split("|")
          .map((c) => renderInlineMarkdown(escapeHtml(c.trim()), inlineCodes));
      const headers = parseRow(trimmed);
      i += 2;
      const rows = [];
      while (i < lines.length && lines[i].trim().startsWith("|") && lines[i].trim().endsWith("|")) {
        rows.push(parseRow(lines[i]));
        i++;
      }
      const thead = `<thead><tr>${headers.map((h) => `<th>${h}</th>`).join("")}</tr></thead>`;
      const tbody = `<tbody>${rows
        .map((r) => `<tr>${r.map((c) => `<td>${c}</td>`).join("")}</tr>`)
        .join("")}</tbody>`;
      htmlParts.push(`<div class="md-table-wrap"><table class="md-table">${thead}${tbody}</table></div>`);
      continue;
    }

    if (/^>\s?/.test(trimmed)) {
      const qLines = [];
      while (i < lines.length && /^>\s?/.test(lines[i].trim())) {
        qLines.push(
          renderInlineMarkdown(escapeHtml(lines[i].trim().replace(/^>\s?/, "")), inlineCodes)
        );
        i++;
      }
      htmlParts.push(`<blockquote>${qLines.join("<br />")}</blockquote>`);
      continue;
    }

    if (/^(?:[-*•])\s+/.test(trimmed)) {
      const items = [];
      while (i < lines.length && /^(?:[-*•])\s+/.test(lines[i].trim())) {
        const itemText = lines[i].trim().replace(/^(?:[-*•])\s+/, "");
        items.push(`<li>${renderInlineMarkdown(escapeHtml(itemText), inlineCodes)}</li>`);
        i++;
      }
      htmlParts.push(`<ul>${items.join("")}</ul>`);
      continue;
    }

    if (/^\d+\.\s+/.test(trimmed)) {
      const items = [];
      while (i < lines.length && /^\d+\.\s+/.test(lines[i].trim())) {
        const itemText = lines[i].trim().replace(/^\d+\.\s+/, "");
        items.push(`<li>${renderInlineMarkdown(escapeHtml(itemText), inlineCodes)}</li>`);
        i++;
      }
      htmlParts.push(`<ol>${items.join("")}</ol>`);
      continue;
    }

    const pLines = [];
    while (
      i < lines.length &&
      lines[i].trim() &&
      !/^\u0000CODEBLOCK_\d+\u0000$/.test(lines[i].trim()) &&
      !/^(#{1,6}\s+|(?:---|\*\*\*|___)\s*$|>\s?|(?:[-*•])\s+|\d+\.\s+)/.test(lines[i].trim())
    ) {
      pLines.push(renderInlineMarkdown(escapeHtml(lines[i]), inlineCodes));
      i++;
    }
    if (pLines.length > 0) {
      htmlParts.push(`<p>${pLines.join("<br />")}</p>`);
    } else {
      i++;
    }
  }

  return htmlParts.join("");
}

// --- Boot & Auth ---

async function boot() {
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("/sw.js").catch(() => {});
  }
  if (!state.token) {
    $("auth-view").classList.remove("hidden");
    return;
  }
  try {
    const res = await api("/api/settings");
    await enterApp(res);
  } catch {
    $("auth-view").classList.remove("hidden");
  }
}

$("auth-submit-btn").addEventListener("click", async () => {
  const token = $("auth-token-input").value.trim();
  if (!token) return;
  $("auth-error").classList.add("hidden");
  try {
    const res = await fetch("/api/auth/verify", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ token }),
    });
    if (!res.ok) throw new Error("Token 错误");
    const data = await res.json();
    state.token = token;
    localStorage.setItem(TOKEN_KEY, token);
    await enterApp(data.settings);
  } catch (err) {
    $("auth-error").textContent = err.message;
    $("auth-error").classList.remove("hidden");
  }
});

async function enterApp(settings) {
  state.settings = settings;
  $("auth-view").classList.add("hidden");
  $("main-view").classList.remove("hidden");
  const filterChk = $("filter-ws-sessions-chk");
  if (filterChk) filterChk.checked = state.filterSessionsByWorkspace;

  populateSettingsUI(settings);
  populateWorkspaces(settings.workspaces || []);
  syncQuickModelSelect(settings.model || "deepseek-chat");
  await loadWorkspaceProfiles();
  await loadSessions();
  await loadDirectory("");
  await refreshGitStatus();
  refreshWalletSummary().catch(() => {});
}

function syncQuickModelSelect(modelName) {
  const sel = $("quick-model-select");
  if (!sel) return;
  if (!Array.from(sel.options).some((o) => o.value === modelName)) {
    const opt = document.createElement("option");
    opt.value = modelName;
    opt.textContent = modelName;
    sel.appendChild(opt);
  }
  sel.value = modelName;
}

function populateWorkspaces(workspaces) {
  const sel = $("workspace-select");
  if (!sel) return;
  sel.innerHTML = "";
  for (const ws of workspaces) {
    const opt = document.createElement("option");
    opt.value = ws;
    const parts = ws.split(/[/\\]/).filter(Boolean);
    opt.textContent = parts[parts.length - 1] || ws;
    sel.appendChild(opt);
  }
  if (!workspaces.includes(state.workspace)) {
    state.workspace = workspaces[0] || "";
  }
  sel.value = state.workspace;
  localStorage.setItem(ACTIVE_WS_KEY, state.workspace);
}

$("workspace-select").addEventListener("change", async (e) => {
  state.workspace = e.target.value;
  localStorage.setItem(ACTIVE_WS_KEY, state.workspace);
  closeEditorPane(true);
  await loadDirectory("");
  await refreshGitStatus();
  showToast("已切换工作区目录");
});

// =========================================================================
// Module A: Workspace Profiles Switcher & Manager
// =========================================================================

async function loadWorkspaceProfiles() {
  try {
    const res = await api("/api/workspace-profiles");
    const list = res.workspace_profiles || res.profiles || (Array.isArray(res) ? res : []);
    state.workspaceProfiles = list;
    if (res.active_workspace_profile_id) {
      state.activeWorkspaceProfileId = res.active_workspace_profile_id;
    } else if (state.settings?.active_workspace_profile_id) {
      state.activeWorkspaceProfileId = state.settings.active_workspace_profile_id;
    } else if (list.length > 0 && !list.some((p) => p.id === state.activeWorkspaceProfileId)) {
      state.activeWorkspaceProfileId = list[0].id;
    }
  } catch {
    const fallback = state.settings?.workspace_profiles || [
      {
        id: "ws_default",
        name: "默认工作区",
        root_dir: state.workspace,
        shared_notes: "",
        cross_session_read: true,
      },
    ];
    state.workspaceProfiles = fallback;
  }
  localStorage.setItem(ACTIVE_WS_PROFILE_KEY, state.activeWorkspaceProfileId);
  renderWorkspaceProfileSelect();
}

function renderWorkspaceProfileSelect() {
  const sel = $("workspace-profile-select");
  if (!sel) return;
  sel.innerHTML = "";
  const profiles = state.workspaceProfiles.length
    ? state.workspaceProfiles
    : [{ id: "ws_default", name: "默认工作区", root_dir: state.workspace }];

  for (const p of profiles) {
    const opt = document.createElement("option");
    opt.value = p.id;
    opt.textContent = `🗂️ ${p.name || p.id}`;
    sel.appendChild(opt);
  }
  if (profiles.some((p) => p.id === state.activeWorkspaceProfileId)) {
    sel.value = state.activeWorkspaceProfileId;
  } else if (profiles[0]) {
    state.activeWorkspaceProfileId = profiles[0].id;
    sel.value = state.activeWorkspaceProfileId;
  }
}

$("workspace-profile-select")?.addEventListener("change", async (e) => {
  const nextId = e.target.value;
  await activateWorkspaceProfile(nextId);
});

async function activateWorkspaceProfile(profileId) {
  state.activeWorkspaceProfileId = profileId;
  localStorage.setItem(ACTIVE_WS_PROFILE_KEY, profileId);
  try {
    await api(`/api/workspace-profiles/${encodeURIComponent(profileId)}/activate`, {
      method: "POST",
    });
  } catch {
    // Fallback if server uses PUT /api/workspace-profiles/{id} or settings
  }
  const prof = state.workspaceProfiles.find((p) => p.id === profileId);
  const rootDir = prof?.root_dir || prof?.workspace || "";
  if (rootDir) {
    state.workspace = rootDir;
    localStorage.setItem(ACTIVE_WS_KEY, rootDir);
    if ($("workspace-select")) {
      if (!Array.from($("workspace-select").options).some((o) => o.value === rootDir)) {
        const opt = document.createElement("option");
        opt.value = rootDir;
        opt.textContent = rootDir.split(/[/\\]/).filter(Boolean).pop() || rootDir;
        $("workspace-select").appendChild(opt);
      }
      $("workspace-select").value = rootDir;
    }
    await loadDirectory("").catch(() => {});
    await refreshGitStatus().catch(() => {});
  }
  renderSessionList();
  showToast(`已切换工作区档案: ${prof?.name || profileId}`);
}

function openWorkspaceProfileModal(selectId = null) {
  const modal = $("workspace-profile-modal");
  if (!modal) return;
  modal.classList.remove("hidden");
  const sel = $("ws-modal-select");
  sel.innerHTML = "";
  for (const p of state.workspaceProfiles) {
    const opt = document.createElement("option");
    opt.value = p.id;
    opt.textContent = `${p.name || p.id} (${p.id})`;
    sel.appendChild(opt);
  }
  const newOpt = document.createElement("option");
  newOpt.value = "__new__";
  newOpt.textContent = "＋ 新建工作区档案...";
  sel.appendChild(newOpt);

  const targetId = selectId || state.activeWorkspaceProfileId || (state.workspaceProfiles[0]?.id ?? "__new__");
  sel.value = targetId;
  populateWsModalFields(targetId);
}

function populateWsModalFields(profileId) {
  if (profileId === "__new__") {
    $("ws-modal-name").value = "";
    $("ws-modal-root").value = state.workspace || "";
    $("ws-modal-notes").value = "";
    $("ws-modal-cross-read").checked = true;
    $("ws-modal-delete-btn").disabled = true;
    return;
  }
  const p = state.workspaceProfiles.find((item) => item.id === profileId);
  $("ws-modal-name").value = p?.name || "";
  $("ws-modal-root").value = p?.root_dir || p?.workspace || state.workspace || "";
  $("ws-modal-notes").value = p?.shared_notes || "";
  $("ws-modal-cross-read").checked = p?.cross_session_read !== false;
  $("ws-modal-delete-btn").disabled = profileId === "ws_default" || state.workspaceProfiles.length <= 1;
}

$("manage-workspace-profile-btn")?.addEventListener("click", () => openWorkspaceProfileModal());
$("close-ws-modal-btn")?.addEventListener("click", () => $("workspace-profile-modal").classList.add("hidden"));
$("ws-modal-select")?.addEventListener("change", (e) => populateWsModalFields(e.target.value));
$("ws-modal-new-btn")?.addEventListener("click", () => {
  $("ws-modal-select").value = "__new__";
  populateWsModalFields("__new__");
  $("ws-modal-name").focus();
});

$("ws-modal-save-btn")?.addEventListener("click", async () => {
  const selId = $("ws-modal-select").value;
  const payload = {
    name: $("ws-modal-name").value.trim() || "未命名工作区",
    root_dir: $("ws-modal-root").value.trim() || state.workspace,
    workspace: $("ws-modal-root").value.trim() || state.workspace,
    shared_notes: $("ws-modal-notes").value,
    cross_session_read: $("ws-modal-cross-read").checked,
  };
  try {
    let savedId = selId;
    if (selId === "__new__") {
      const res = await api("/api/workspace-profiles", {
        method: "POST",
        body: JSON.stringify(payload),
      });
      const created = res.profile || res.workspace_profile || res;
      savedId = created.id || state.activeWorkspaceProfileId;
    } else {
      await api(`/api/workspace-profiles/${encodeURIComponent(selId)}`, {
        method: "PUT",
        body: JSON.stringify(payload),
      });
    }
    await loadWorkspaceProfiles();
    if (savedId && savedId !== "__new__") {
      await activateWorkspaceProfile(savedId);
    }
    $("workspace-profile-modal").classList.add("hidden");
    showToast("工作区档案已保存");
  } catch (err) {
    showToast(err.message);
  }
});

$("ws-modal-delete-btn")?.addEventListener("click", async () => {
  const selId = $("ws-modal-select").value;
  if (!selId || selId === "__new__" || selId === "ws_default") return;
  if (!confirm("确定删除该工作区档案？")) return;
  try {
    await api(`/api/workspace-profiles/${encodeURIComponent(selId)}`, { method: "DELETE" });
    await loadWorkspaceProfiles();
    $("workspace-profile-modal").classList.add("hidden");
    showToast("工作区档案已删除");
  } catch (err) {
    showToast(err.message);
  }
});

$("filter-ws-sessions-chk")?.addEventListener("change", (e) => {
  state.filterSessionsByWorkspace = e.target.checked;
  localStorage.setItem(FILTER_WS_SESSIONS_KEY, state.filterSessionsByWorkspace ? "1" : "0");
  renderSessionList();
});

// --- Tabs ---

document.querySelectorAll(".nav-btn").forEach((btn) => {
  btn.addEventListener("click", () => switchTab(btn.dataset.tab));
});

function switchTab(tabName) {
  document.querySelectorAll(".nav-btn").forEach((b) => {
    b.classList.toggle("active", b.dataset.tab === tabName);
  });
  document.querySelectorAll(".tab-panel").forEach((p) => {
    p.classList.toggle("active", p.id === `tab-${tabName}`);
  });
  if (tabName === "git") {
    refreshGitStatus();
    refreshWalletSummary().catch(() => {});
  }
}

// =========================================================================
// Module C: Sessions, Rename/Delete, Turn Operations & WebSocket Sync
// =========================================================================

async function loadSessions() {
  const data = await api("/api/sessions");
  state.sessions = data.sessions || [];
  if (state.sessions.length === 0) {
    const created = await api("/api/sessions", {
      method: "POST",
      body: JSON.stringify({
        workspace: state.workspace,
        workspace_profile_id: state.activeWorkspaceProfileId,
        title: "DeepSeek Session",
        model: $("quick-model-select").value,
      }),
    });
    state.sessions = [created];
  }
  if (!state.sessions.some((s) => s.session_id === state.activeSessionId)) {
    state.activeSessionId = state.sessions[0].session_id;
  }
  renderSessionList();
  await selectSession(state.activeSessionId);
}

function renderSessionList() {
  const list = $("session-list");
  if (!list) return;
  list.innerHTML = "";

  const visibleSessions = state.filterSessionsByWorkspace
    ? state.sessions.filter(
        (s) =>
          !s.workspace_profile_id ||
          s.workspace_profile_id === state.activeWorkspaceProfileId ||
          s.session_id === state.activeSessionId
      )
    : state.sessions;

  for (const s of visibleSessions) {
    const item = document.createElement("div");
    item.className = `session-item ${s.session_id === state.activeSessionId ? "active" : ""}`;
    const meta = document.createElement("div");
    meta.className = "session-meta";
    const wsBadge = s.workspace_profile_id && s.workspace_profile_id !== "ws_default" ? ` · ${s.workspace_profile_id}` : "";
    meta.innerHTML = `<div class="session-title"></div><div class="session-sub">${escapeHtml(s.model || "deepseek-chat")} · ${escapeHtml(s.status)}${escapeHtml(wsBadge)}</div>`;
    meta.querySelector(".session-title").textContent = s.title;
    meta.addEventListener("click", async () => {
      closeDrawer();
      await selectSession(s.session_id);
    });

    const actions = document.createElement("div");
    actions.className = "session-actions";

    const ren = document.createElement("button");
    ren.className = "btn small";
    ren.textContent = "改名";
    ren.addEventListener("click", async (e) => {
      e.stopPropagation();
      await promptRenameSession(s.session_id, s.title);
    });

    const del = document.createElement("button");
    del.className = "btn small danger-outline";
    del.textContent = "删";
    del.addEventListener("click", async (e) => {
      e.stopPropagation();
      if (!confirm(`删除会话 "${s.title}"？`)) return;
      await api(`/api/sessions/${s.session_id}`, { method: "DELETE" });
      await loadSessions();
    });

    actions.append(ren, del);
    item.append(meta, actions);
    list.appendChild(item);
  }
}

async function promptRenameSession(sessionId, currentTitle = "") {
  const nextTitle = prompt("输入新的会话标题：", currentTitle || "");
  if (!nextTitle || !nextTitle.trim() || nextTitle.trim() === currentTitle) return;
  try {
    const res = await api(`/api/sessions/${sessionId}`, {
      method: "PATCH",
      body: JSON.stringify({ title: nextTitle.trim() }),
    });
    const updated = res.session || res;
    const idx = state.sessions.findIndex((item) => item.session_id === sessionId);
    if (idx >= 0) {
      state.sessions[idx] = { ...state.sessions[idx], ...updated, title: nextTitle.trim() };
    }
    if (sessionId === state.activeSessionId) {
      $("header-session-title").textContent = nextTitle.trim();
    }
    renderSessionList();
    showToast("会话已重命名");
  } catch (err) {
    showToast(err.message);
  }
}

$("header-session-title")?.addEventListener("click", () => {
  if (!state.activeSessionId) return;
  const cur = state.sessions.find((s) => s.session_id === state.activeSessionId);
  promptRenameSession(state.activeSessionId, cur?.title || $("header-session-title").textContent);
});

async function selectSession(sessionId) {
  state.activeSessionId = sessionId;
  localStorage.setItem(ACTIVE_SESSION_KEY, sessionId);
  state.lastSeq = 0;
  state.currentTurn = null;
  state.activeTurnId = "";
  state.resolvingIds.clear();
  $("chat-messages").innerHTML = "";
  $("pending-box").innerHTML = "";
  $("pending-box").classList.add("hidden");

  const active = state.sessions.find((s) => s.session_id === sessionId);
  if (active) {
    $("header-session-title").textContent = active.title;
    if (active.model) syncQuickModelSelect(active.model);
  }
  renderSessionList();
  connectSessionSocket(true);
}

let _wsHeartbeatTimer = null;
let _wsLastActivityAt = 0;
let _wsBackoffAttempt = 0;

function connectSessionSocket(reset = false) {
  if (state.ws) {
    state.ws.onclose = null;
    state.ws.close();
  }
  clearTimeout(state.reconnectTimer);
  clearInterval(_wsHeartbeatTimer);
  if (!state.activeSessionId || !state.token) return;

  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  const after = reset ? 0 : state.lastSeq;
  const wsUrl = `${proto}//${location.host}/ws/sessions/${state.activeSessionId}?token=${encodeURIComponent(state.token)}&after_seq=${after}`;
  setConnStatus("reconnecting", "同步中...");

  const ws = new WebSocket(wsUrl);
  state.ws = ws;
  state.wsSynced = false;
  _wsLastActivityAt = Date.now();

  ws.onopen = () => {
    _wsLastActivityAt = Date.now();
    setConnStatus("online", "已连接");
    _wsHeartbeatTimer = setInterval(() => {
      if (state.ws !== ws) return;
      if (Date.now() - _wsLastActivityAt > 35000) {
        setConnStatus("reconnecting", "心跳超时，重连中...");
        try { ws.close(); } catch {}
        return;
      }
      if (ws.readyState === WebSocket.OPEN) {
        try { ws.send("ping"); } catch {}
      }
    }, 12000);
  };

  ws.onmessage = (evt) => {
    _wsLastActivityAt = Date.now();
    const msg = JSON.parse(evt.data);
    if (msg.type === "ping" || msg.type === "pong") return;
    if (msg.type === "sync_complete") {
      state.wsSynced = true;
      _wsBackoffAttempt = 0;
      if (msg.session) updateSessionMeta(msg.session);
      scrollChatBottom(true);
      return;
    }
    if (typeof msg.seq === "number") {
      if (msg.seq <= state.lastSeq) return;
      state.lastSeq = msg.seq;
    }
    renderEvent(msg);
  };

  ws.onclose = () => {
    clearInterval(_wsHeartbeatTimer);
    if (state.ws !== ws) return;
    _wsBackoffAttempt = Math.min(_wsBackoffAttempt + 1, 6);
    const delay = Math.min(15000, Math.round(1000 * Math.pow(1.6, _wsBackoffAttempt - 1) + Math.random() * 400));
    setConnStatus("reconnecting", "重连中...");
    state.reconnectTimer = setTimeout(() => connectSessionSocket(false), delay);
  };

  ws.onerror = () => {
    try { ws.close(); } catch {}
  };
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && state.token && state.activeSessionId) {
    if (!state.ws || state.ws.readyState !== WebSocket.OPEN || (Date.now() - _wsLastActivityAt > 30000)) {
      connectSessionSocket(false);
    }
  }
});

function updateSessionMeta(summary) {
  if (!summary) return;
  $("header-session-title").textContent = summary.title;
  const idx = state.sessions.findIndex((s) => s.session_id === summary.session_id);
  if (idx >= 0) {
    state.sessions[idx] = { ...state.sessions[idx], ...summary };
    renderSessionList();
  }
  if (summary.model) syncQuickModelSelect(summary.model);
  const running = summary.status === "running" || summary.status === "waiting_input";
  $("agent-state-pill").textContent =
    summary.status === "waiting_input"
      ? "等待你的确认"
      : running
        ? "DeepSeek 运行中..."
        : "空闲";
  $("send-btn").classList.toggle("hidden", running);
  $("cancel-btn").classList.toggle("hidden", !running);
  renderPendingBox(summary);
}

function scrollChatBottom(force = false) {
  if (state.scrollRaf) return;
  state.scrollRaf = requestAnimationFrame(() => {
    state.scrollRaf = null;
    const box = $("chat-messages");
    if (!box) return;
    const nearBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 140;
    if (force || nearBottom) {
      box.scrollTop = box.scrollHeight;
    }
  });
}

// --- Turn-Scoped Grouped Rendering + Turn Operations ---

function ensureCurrentTurn(turnId = "") {
  const effectiveTurnId = turnId || state.activeTurnId || "";
  if (state.currentTurn) {
    if (effectiveTurnId && !state.currentTurn.turnId) {
      state.currentTurn.turnId = effectiveTurnId;
      state.currentTurn.processWrap.dataset.turnId = effectiveTurnId;
      if (state.currentTurn.assistantEl) {
        state.currentTurn.assistantEl.dataset.turnId = effectiveTurnId;
      }
    }
    return state.currentTurn;
  }
  const box = $("chat-messages");
  const processWrap = document.createElement("div");
  processWrap.className = "turn-process-wrap hidden";
  if (effectiveTurnId) processWrap.dataset.turnId = effectiveTurnId;
  box.appendChild(processWrap);

  state.currentTurn = {
    turnId: effectiveTurnId,
    processWrap,
    thoughtDetails: null,
    thoughtBadge: null,
    thoughtPre: null,
    thoughtRounds: [""],
    thoughtRoundIdx: 0,
    lastEventWasThought: false,
    toolsDetails: null,
    toolsBadge: null,
    toolsBody: null,
    toolCount: 0,
    toolItemsById: new Map(),
    lastToolName: "",
    assistantEl: null,
    assistantContentEl: null,
    assistantFooterEl: null,
    assistantUsageBadgeEl: null,
    textRounds: [""],
    textRoundIdx: 0,
    lastEventWasText: false,
  };
  return state.currentTurn;
}

function ensureThoughtDrawer(turn) {
  if (turn.thoughtDetails) return;
  turn.processWrap.classList.remove("hidden");
  const details = document.createElement("details");
  details.className = "process-group thought-group";
  details.innerHTML = `
    <summary>
      <span class="process-summary-left">💭 深度思考</span>
      <span class="process-badge">思考中...</span>
    </summary>
    <div class="process-body">
      <div class="thought-text"></div>
    </div>`;
  turn.processWrap.prepend(details);
  turn.thoughtDetails = details;
  turn.thoughtBadge = details.querySelector(".process-badge");
  turn.thoughtPre = details.querySelector(".thought-text");
}

function ensureToolsDrawer(turn) {
  if (turn.toolsDetails) return;
  turn.processWrap.classList.remove("hidden");
  const details = document.createElement("details");
  details.className = "process-group tools-group";
  details.innerHTML = `
    <summary>
      <span class="process-summary-left">🧰 工具调用</span>
      <span class="process-badge">已收纳</span>
    </summary>
    <div class="process-body"></div>`;
  turn.processWrap.appendChild(details);
  turn.toolsDetails = details;
  turn.toolsBadge = details.querySelector(".process-badge");
  turn.toolsBody = details.querySelector(".process-body");
}

function createTurnActionsBar({ turnId, getTextFn, isUser = false, editPromptFn = null }) {
  const actions = document.createElement("div");
  actions.className = "turn-actions";

  const copyBtn = document.createElement("button");
  copyBtn.type = "button";
  copyBtn.className = "turn-act-btn";
  copyBtn.textContent = "复制";
  copyBtn.addEventListener("click", () => copyText(getTextFn(), "本轮内容已复制"));
  actions.appendChild(copyBtn);

  if (isUser && editPromptFn) {
    const editBtn = document.createElement("button");
    editBtn.type = "button";
    editBtn.className = "turn-act-btn";
    editBtn.textContent = "编辑重发";
    editBtn.addEventListener("click", () => editPromptFn());
    actions.appendChild(editBtn);
  }

  const regenBtn = document.createElement("button");
  regenBtn.type = "button";
  regenBtn.className = "turn-act-btn";
  regenBtn.textContent = "重新生成";
  regenBtn.addEventListener("click", () => handleRegenerateTurn(turnId));
  actions.appendChild(regenBtn);

  const delBtn = document.createElement("button");
  delBtn.type = "button";
  delBtn.className = "turn-act-btn danger";
  delBtn.textContent = "删除本轮";
  delBtn.addEventListener("click", () => handleDeleteTurn(turnId));
  actions.appendChild(delBtn);

  return actions;
}

function ensureAssistantBubble(turn) {
  if (turn.assistantEl) return;
  const box = $("chat-messages");
  const div = document.createElement("div");
  div.className = "msg assistant";
  if (turn.turnId) div.dataset.turnId = turn.turnId;

  const md = document.createElement("div");
  md.className = "md-content";

  const footer = document.createElement("div");
  footer.className = "turn-footer-bar";

  const usageBadge = document.createElement("span");
  usageBadge.className = "turn-usage-badge hidden";

  const actions = createTurnActionsBar({
    turnId: () => turn.turnId,
    getTextFn: () => turn.textRounds.filter(Boolean).join("\n\n"),
    isUser: false,
  });

  footer.append(usageBadge, actions);
  div.append(md, footer);
  box.appendChild(div);
  turn.assistantEl = div;
  turn.assistantContentEl = md;
  turn.assistantFooterEl = footer;
  turn.assistantUsageBadgeEl = usageBadge;
}

async function handleEditAndResendTurn(turnId, originalText) {
  const resolvedId = typeof turnId === "function" ? turnId() : turnId;
  if (!resolvedId) {
    showToast("当前消息无 turn_id，无法直接编辑");
    return;
  }
  const nextPrompt = prompt("编辑并重新发送该轮提示词（后续轮次将被截断重跑）：", originalText || "");
  if (!nextPrompt || !nextPrompt.trim()) return;
  try {
    await api(`/api/sessions/${state.activeSessionId}/turns/${encodeURIComponent(resolvedId)}/edit`, {
      method: "POST",
      body: JSON.stringify({
        prompt: nextPrompt.trim(),
        model: $("quick-model-select").value,
      }),
    });
    showToast("已修改并重新生成");
    await selectSession(state.activeSessionId);
  } catch (err) {
    showToast(err.message);
  }
}

async function handleRegenerateTurn(turnId) {
  const resolvedId = typeof turnId === "function" ? turnId() : turnId;
  if (!resolvedId) {
    showToast("当前回合无 turn_id，无法重新生成");
    return;
  }
  try {
    await api(`/api/sessions/${state.activeSessionId}/turns/${encodeURIComponent(resolvedId)}/regenerate`, {
      method: "POST",
      body: JSON.stringify({ model: $("quick-model-select").value }),
    });
    showToast("正在重新生成本轮回复...");
    await selectSession(state.activeSessionId);
  } catch (err) {
    showToast(err.message);
  }
}

async function handleDeleteTurn(turnId) {
  const resolvedId = typeof turnId === "function" ? turnId() : turnId;
  if (!resolvedId) {
    showToast("当前回合无 turn_id");
    return;
  }
  if (!confirm("确定删除本轮对话记录？")) return;
  try {
    await api(`/api/sessions/${state.activeSessionId}/turns/${encodeURIComponent(resolvedId)}`, {
      method: "DELETE",
    });
    removeTurnDomNodes(resolvedId);
    showToast("已删除该轮对话");
  } catch (err) {
    showToast(err.message);
  }
}

function removeTurnDomNodes(turnId) {
  if (!turnId) return;
  document.querySelectorAll(`[data-turn-id="${CSS.escape(turnId)}"]`).forEach((el) => el.remove());
}

function summarizeToolArg(name, args) {
  if (!args || typeof args !== "object") return "";
  if (args.path) return String(args.path);
  if (args.command) return String(args.command).slice(0, 42);
  if (args.url) return String(args.url).slice(0, 42);
  if (args.query) return String(args.query);
  if (args.question) return String(args.question).slice(0, 42);
  return "";
}

function finalizeTurnDrawers(turn) {
  if (!turn) return;
  if (turn.thoughtBadge) {
    const totalChars = turn.thoughtRounds.join("").trim().length;
    turn.thoughtBadge.textContent = `已收纳 · ${totalChars} 字`;
  }
  if (turn.toolsBadge) {
    turn.toolsBadge.textContent = `已收纳 · ${turn.toolCount} 次调用`;
  }
}

function renderTurnAttachmentsGrid(rawAttachments) {
  if (!Array.isArray(rawAttachments) || rawAttachments.length === 0) return null;
  const grid = document.createElement("div");
  grid.className = "turn-attachments-grid";
  for (const item of rawAttachments) {
    const attId = typeof item === "string" ? item : item?.att_id || item?.id;
    const thumbUrl =
      typeof item === "object" && item?.thumb_url
        ? item.thumb_url
        : attId
          ? `/api/attachments/${encodeURIComponent(attId)}/thumb`
          : "";
    const fullUrl =
      typeof item === "object" && item?.url
        ? item.url
        : attId
          ? `/api/attachments/${encodeURIComponent(attId)}`
          : thumbUrl;
    const filename = (typeof item === "object" && item?.filename) || attId || "图片附件";
    if (!thumbUrl && !fullUrl) continue;

    const img = document.createElement("img");
    img.className = "turn-att-img";
    img.src = authUrl(thumbUrl || fullUrl);
    img.alt = filename;
    img.loading = "lazy";
    img.addEventListener("click", () => openLightbox(authUrl(fullUrl), filename));
    grid.appendChild(img);
  }
  return grid.children.length > 0 ? grid : null;
}

function renderFileArtifactCard(art, turnId = "") {
  const box = $("chat-messages");
  if (!box || !art) return;
  const ext = String(art.ext || "").toLowerCase();
  const isImg =
    Boolean(art.is_image) ||
    [".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp"].includes(ext) ||
    String(art.mime_type || "").startsWith("image/");
  const imgRawUrl =
    art.image_url ||
    art.url ||
    (art.att_id ? `/api/attachments/${encodeURIComponent(art.att_id)}` : "") ||
    (art.path ? `/api/pc/download?path=${encodeURIComponent(art.path)}` : "");
  const fullSrc = imgRawUrl ? authUrl(imgRawUrl) : "";
  const titleText = art.title || art.name || art.filename || (isImg ? "图片预览" : "文件产物");
  const sizeBadge =
    isImg && art.width && art.height
      ? `${art.width}×${art.height}`
      : art.size
        ? formatBytes(art.size)
        : "";

  const card = document.createElement("div");
  card.className = "browser-chat-card";
  card.style.margin = "8px 0";
  if (turnId) card.dataset.turnId = turnId;

  const header = document.createElement("div");
  header.className = "browser-card-header";
  header.innerHTML = `
    <div style="display:flex;align-items:center;gap:8px;min-width:0;">
      <span>${isImg ? "🖼️" : "📄"}</span>
      <strong style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">${escapeHtml(titleText)}</strong>
    </div>
    ${sizeBadge ? `<span class="state-pill">${escapeHtml(sizeBadge)}</span>` : ""}
  `;
  card.appendChild(header);

  if (art.summary) {
    const sum = document.createElement("div");
    sum.style.fontSize = "12.5px";
    sum.style.opacity = "0.78";
    sum.style.margin = "4px 12px 8px";
    sum.textContent = art.summary;
    card.appendChild(sum);
  }

  if (isImg && fullSrc) {
    const imgWrap = document.createElement("div");
    imgWrap.style.margin = "4px 12px 10px";
    imgWrap.style.borderRadius = "12px";
    imgWrap.style.overflow = "hidden";
    imgWrap.style.background = "rgba(0,0,0,0.06)";
    imgWrap.style.cursor = "zoom-in";

    const imgEl = document.createElement("img");
    imgEl.src = fullSrc;
    imgEl.alt = titleText;
    imgEl.loading = "lazy";
    imgEl.style.display = "block";
    imgEl.style.width = "100%";
    imgEl.style.maxHeight = "320px";
    imgEl.style.objectFit = "contain";
    imgEl.addEventListener("click", () => openLightbox(fullSrc, titleText));
    imgWrap.appendChild(imgEl);
    card.appendChild(imgWrap);
  } else if (art.is_text && art.preview) {
    const pre = document.createElement("pre");
    pre.style.margin = "4px 12px 10px";
    pre.style.padding = "10px";
    pre.style.borderRadius = "10px";
    pre.style.background = "rgba(0,0,0,0.05)";
    pre.style.fontSize = "11.5px";
    pre.style.maxHeight = "160px";
    pre.style.overflow = "auto";
    pre.textContent = String(art.preview).split("\n").slice(0, 8).join("\n");
    card.appendChild(pre);
  }

  const actions = document.createElement("div");
  actions.style.display = "flex";
  actions.style.gap = "8px";
  actions.style.padding = "0 12px 10px";

  if (isImg && fullSrc) {
    const prevBtn = document.createElement("button");
    prevBtn.type = "button";
    prevBtn.className = "chip-btn action-chip";
    prevBtn.textContent = "🔍 全屏预览图片";
    prevBtn.addEventListener("click", () => openLightbox(fullSrc, titleText));
    actions.appendChild(prevBtn);
  }

  if (art.path || fullSrc) {
    const dlUrl = art.path
      ? authUrl(`/api/pc/download?path=${encodeURIComponent(art.path)}`)
      : fullSrc;
    const dlLink = document.createElement("a");
    dlLink.className = "chip-btn action-chip";
    dlLink.href = dlUrl;
    dlLink.download = art.name || art.filename || "download";
    dlLink.textContent = "⬇️ 下载";
    dlLink.style.textDecoration = "none";
    actions.appendChild(dlLink);
  }

  card.appendChild(actions);
  box.appendChild(card);
}

function renderEvent(ev) {
  const box = $("chat-messages");
  const d = ev.data || {};
  const turnId = ev.turn_id || d.turn_id || "";
  if (turnId) state.activeTurnId = turnId;

  if (d.session) {
    updateSessionMeta(d.session);
  }

  // Module C WebSocket events
  if (ev.type === "session_updated") {
    updateSessionMeta(d.session || d);
    return;
  }

  if (ev.type === "turn_deleted") {
    const delId = d.turn_id || turnId;
    if (delId) {
      removeTurnDomNodes(delId);
    } else {
      selectSession(state.activeSessionId);
    }
    return;
  }

  if (ev.type === "turns_truncated") {
    const ids = d.removed_turn_ids || d.turn_ids || [];
    if (Array.isArray(ids) && ids.length > 0) {
      ids.forEach((id) => removeTurnDomNodes(id));
    } else {
      selectSession(state.activeSessionId);
    }
    return;
  }

  // Module E auto-downgrade notice
  if (ev.type === "model_auto_switched") {
    const banner = document.createElement("div");
    banner.className = "model-switch-banner";
    if (turnId) banner.dataset.turnId = turnId;
    const fromModel = d.from_model || d.from_profile_id || "原模型";
    const toModel = d.model || d.profile_id || "deepseek-flash";
    const reason = d.reason || "触发额度/余额降级规则";
    banner.innerHTML = `<span>⚡ <strong>自动降级已生效</strong>: ${escapeHtml(fromModel)} → <strong>${escapeHtml(toModel)}</strong> (${escapeHtml(reason)})</span>`;
    box.appendChild(banner);
    syncQuickModelSelect(toModel);
    scrollChatBottom();
    return;
  }

  // Module F inline collaborative browser state
  if (ev.type === "browser_state") {
    renderOrUpdateBrowserCard(d.browser || d, turnId);
    scrollChatBottom();
    return;
  }

  // Module D agent team update card
  if (ev.type === "agent_team_update") {
    renderOrUpdateAgentTeamCard(d, turnId);
    scrollChatBottom();
    return;
  }

  // Module B / Artifact Card (including AI take_screenshot & present_file image previews)
  if (ev.type === "file_artifact" || ev.type === "image_attachment") {
    renderFileArtifactCard(d, turnId);
    scrollChatBottom();
    return;
  }

  if (ev.type === "user_message") {
    finalizeTurnDrawers(state.currentTurn);
    state.currentTurn = null;
    const div = document.createElement("div");
    div.className = "msg user";
    if (turnId) div.dataset.turnId = turnId;

    const cleanPrompt = normalizeCleanText(d.text || "");
    const textSpan = document.createElement("div");
    textSpan.textContent = cleanPrompt;
    div.appendChild(textSpan);

    const attList = d.attachments || d.attachment_ids || [];
    const attGrid = renderTurnAttachmentsGrid(attList);
    if (attGrid) div.appendChild(attGrid);

    const footer = document.createElement("div");
    footer.className = "turn-footer-bar";
    footer.appendChild(
      createTurnActionsBar({
        turnId: () => div.dataset.turnId || turnId,
        getTextFn: () => cleanPrompt,
        isUser: true,
        editPromptFn: () => handleEditAndResendTurn(div.dataset.turnId || turnId, cleanPrompt),
      })
    );
    div.appendChild(footer);

    box.appendChild(div);
    scrollChatBottom(true);
    return;
  }

  if (ev.type === "thought_delta") {
    if (state.wsSynced) setDynamicIslandState("thinking");
    const turn = ensureCurrentTurn(turnId);
    ensureThoughtDrawer(turn);
    if (!turn.lastEventWasThought && turn.thoughtRounds[turn.thoughtRoundIdx]) {
      turn.thoughtRoundIdx += 1;
      turn.thoughtRounds[turn.thoughtRoundIdx] = "";
    }
    turn.lastEventWasThought = true;
    turn.lastEventWasText = false;

    if (d.full_text !== undefined) {
      turn.thoughtRounds[turn.thoughtRoundIdx] = normalizeCleanText(d.full_text);
    } else {
      turn.thoughtRounds[turn.thoughtRoundIdx] += normalizeCleanText(d.text || "");
    }
    const combinedThought = turn.thoughtRounds.filter(Boolean).join("\n\n---\n\n");
    turn.thoughtPre.textContent = combinedThought;
    turn.thoughtBadge.textContent = `已收纳 · ${combinedThought.length} 字`;
  } else if (ev.type === "tool_call") {
    if (state.wsSynced) setDynamicIslandState("tool");
    const turn = ensureCurrentTurn(turnId);
    turn.lastEventWasThought = false;
    turn.lastEventWasText = false;
    ensureToolsDrawer(turn);

    turn.toolCount += 1;
    const toolName = d.name || "tool";
    turn.lastToolName = toolName;
    const argPreview = summarizeToolArg(toolName, d.args);
    turn.toolsBadge.textContent = `已收纳 · ${turn.toolCount} 次 (${toolName})`;

    const item = document.createElement("details");
    item.className = "tool-subitem";
    const callId = d.id || `tc_${turn.toolCount}`;
    item.innerHTML = `
      <summary>
        <span>#${turn.toolCount} 🔧 ${escapeHtml(toolName)}${argPreview ? ` · ${escapeHtml(argPreview)}` : ""}</span>
        <span class="tool-status-tag">⏳ 执行中</span>
      </summary>
      <div class="tool-subitem-body">
        <div class="muted">参数：</div>
        <pre class="tool-args-pre"></pre>
        <div class="tool-result-wrap hidden">
          <div class="muted" style="margin-top:6px">返回结果：</div>
          <pre class="tool-res-pre"></pre>
        </div>
      </div>`;
    item.querySelector(".tool-args-pre").textContent = JSON.stringify(d.args || {}, null, 2);
    turn.toolsBody.appendChild(item);
    turn.toolItemsById.set(callId, item);
  } else if (ev.type === "tool_result") {
    const turn = ensureCurrentTurn(turnId);
    turn.lastEventWasThought = false;
    turn.lastEventWasText = false;
    ensureToolsDrawer(turn);

    const callId = d.id;
    let item = callId ? turn.toolItemsById.get(callId) : null;
    if (!item) {
      turn.toolCount += 1;
      item = document.createElement("details");
      item.className = "tool-subitem";
      item.innerHTML = `
        <summary>
          <span>#${turn.toolCount} 🔧 ${escapeHtml(d.name || "tool")}</span>
          <span class="tool-status-tag"></span>
        </summary>
        <div class="tool-subitem-body">
          <div class="tool-result-wrap">
            <div class="muted">返回结果：</div>
            <pre class="tool-res-pre"></pre>
          </div>
        </div>`;
      turn.toolsBody.appendChild(item);
    }

    const statusTag = item.querySelector(".tool-status-tag");
    if (statusTag) {
      statusTag.textContent = d.error ? "❌ 失败" : "✅ 完成";
    }
    const resWrap = item.querySelector(".tool-result-wrap");
    const resPre = item.querySelector(".tool-res-pre");
    if (resWrap && resPre) {
      resWrap.classList.remove("hidden");
      resPre.textContent = d.error
        ? `Error: ${d.error}`
        : typeof d.result === "string"
          ? normalizeCleanText(d.result)
          : JSON.stringify(d.result, null, 2);
    }
    turn.toolsBadge.textContent = `已收纳 · ${turn.toolCount} 次 (${turn.lastToolName || d.name || "完成"})`;

    // If tool_result returned a screenshot attachment or browser state, render it inline
    const resObj = typeof d.result === "object" && d.result ? d.result : null;
    if (resObj?.att_id || resObj?.attachment?.att_id) {
      ensureAssistantBubble(turn);
      const grid = renderTurnAttachmentsGrid([resObj.attachment || resObj]);
      if (grid) turn.assistantEl.insertBefore(grid, turn.assistantFooterEl);
    }
    if (resObj?.browser_id && (resObj?.frame_b64 || resObj?.last_frame_b64 || resObj?.url)) {
      renderOrUpdateBrowserCard(resObj, turnId);
    }
  } else if (ev.type === "text_delta") {
    if (state.wsSynced) setDynamicIslandState("answering");
    const turn = ensureCurrentTurn(turnId);
    ensureAssistantBubble(turn);
    if (!turn.lastEventWasText && turn.textRounds[turn.textRoundIdx]) {
      turn.textRoundIdx += 1;
      turn.textRounds[turn.textRoundIdx] = "";
    }
    turn.lastEventWasText = true;
    turn.lastEventWasThought = false;

    if (d.full_text !== undefined) {
      turn.textRounds[turn.textRoundIdx] = normalizeCleanText(d.full_text);
    } else {
      turn.textRounds[turn.textRoundIdx] += normalizeCleanText(d.text || "");
    }
    const combinedMarkdown = turn.textRounds.filter(Boolean).join("\n\n");
    turn.assistantContentEl.innerHTML = renderMarkdown(combinedMarkdown);
  } else if (
    ev.type === "approval_request" ||
    ev.type === "interaction_request" ||
    ev.type === "approval_resolved" ||
    ev.type === "interaction_resolved"
  ) {
    if (state.wsSynced && !d.session) refreshActiveSummary();
  } else if (ev.type === "status") {
    if (d.status === "running") {
      $("agent-state-pill").textContent = "DeepSeek 运行中...";
      $("send-btn").classList.add("hidden");
      $("cancel-btn").classList.remove("hidden");
    }
  } else if (ev.type === "turn_done") {
    if (state.wsSynced) setDynamicIslandState("done");
    const turn = state.currentTurn;
    if (turn) {
      finalizeTurnDrawers(turn);
      if (d.usage) {
        ensureAssistantBubble(turn);
        const u = d.usage;
        const pTok = Number(u.prompt_tokens || 0);
        const cHit = Number(u.cache_hit_tokens || 0);
        const compTok = Number(u.completion_tokens || 0);
        const cost = Number(u.cost || 0);
        const modelLabel = u.model || d.model || "";
        if (turn.assistantUsageBadgeEl) {
          turn.assistantUsageBadgeEl.classList.remove("hidden");
          turn.assistantUsageBadgeEl.textContent = `🪙 输入 ${pTok.toLocaleString()}${cHit ? ` (缓存 ${cHit.toLocaleString()})` : ""} · 输出 ${compTok.toLocaleString()} · ¥${cost.toFixed(4)}${modelLabel ? ` · ${modelLabel}` : ""}`;
        }
      }
    }
    state.currentTurn = null;
    state.resolvingIds.clear();
    $("agent-state-pill").textContent = "空闲";
    $("send-btn").classList.remove("hidden");
    $("cancel-btn").classList.add("hidden");
    if (state.wsSynced && !d.session) refreshActiveSummary();
  } else if (ev.type === "error") {
    if (state.wsSynced) setDynamicIslandState("idle");
    finalizeTurnDrawers(state.currentTurn);
    state.currentTurn = null;
    state.resolvingIds.clear();
    const div = document.createElement("div");
    div.className = "msg error";
    if (turnId) div.dataset.turnId = turnId;
    div.textContent = `错误: ${d.message || "网络连接中断，请重试"}`;
    box.appendChild(div);
    $("agent-state-pill").textContent = "错误";
    $("send-btn").classList.remove("hidden");
    $("cancel-btn").classList.add("hidden");
  }
  scrollChatBottom();
}

async function refreshActiveSummary() {
  try {
    const data = await api(`/api/sessions/${state.activeSessionId}/events?after_seq=${state.lastSeq}`);
    if (data.session) updateSessionMeta(data.session);
  } catch {}
}

// =========================================================================
// Module B: Native PC Screenshot, Image Upload & Image Lightbox
// =========================================================================

function renderPendingAttachments() {
  const bar = $("composer-attachments");
  if (!bar) return;
  if (state.pendingAttachments.length === 0) {
    bar.innerHTML = "";
    bar.classList.add("hidden");
    return;
  }
  bar.classList.remove("hidden");
  bar.innerHTML = "";
  for (const att of state.pendingAttachments) {
    const wrap = document.createElement("div");
    wrap.className = "att-Input-thumb";
    const img = document.createElement("img");
    img.src = authUrl(att.thumb_url || att.url);
    img.alt = att.filename || att.att_id;
    img.addEventListener("click", () => openLightbox(authUrl(att.url || att.thumb_url), att.filename));

    const rm = document.createElement("button");
    rm.type = "button";
    rm.className = "att-remove-btn";
    rm.textContent = "✕";
    rm.addEventListener("click", () => {
      state.pendingAttachments = state.pendingAttachments.filter((x) => x.att_id !== att.att_id);
      renderPendingAttachments();
    });

    wrap.append(img, rm);
    bar.appendChild(wrap);
  }
}

$("upload-image-btn")?.addEventListener("click", () => {
  $("image-file-input")?.click();
});

$("image-file-input")?.addEventListener("change", async (e) => {
  const files = Array.from(e.target.files || []);
  e.target.value = "";
  if (!files.length) return;

  for (const file of files) {
    try {
      const b64 = await readFileAsBase64(file);
      const res = await api("/api/attachments", {
        method: "POST",
        body: JSON.stringify({
          filename: file.name,
          base64_data: b64,
          session_id: state.activeSessionId || "global",
        }),
      });
      const meta = res.attachment || res;
      if (meta?.att_id) {
        state.pendingAttachments.push(meta);
        renderPendingAttachments();
      }
    } catch (err) {
      showToast(`图片上传失败: ${err.message}`);
    }
  }
});

function readFileAsBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const str = String(reader.result || "");
      const comma = str.indexOf(",");
      resolve(comma >= 0 ? str.slice(comma + 1) : str);
    };
    reader.onerror = () => reject(new Error("读取本地图片失败"));
    reader.readAsDataURL(file);
  });
}

function openLightbox(imgSrc, caption = "图片预览") {
  const modal = $("image-lightbox-modal");
  const img = $("lightbox-img");
  if (!modal || !img) return;
  state.lightboxZoom = 1;
  img.src = imgSrc;
  img.style.transform = "scale(1)";
  $("lightbox-caption").textContent = caption || "图片预览";
  const dl = $("lightbox-download-link");
  if (dl) dl.href = imgSrc;
  modal.classList.remove("hidden");
}

function updateLightboxZoom(nextZoom) {
  state.lightboxZoom = Math.min(4, Math.max(0.5, nextZoom));
  const img = $("lightbox-img");
  if (img) img.style.transform = `scale(${state.lightboxZoom})`;
  const resetBtn = $("lightbox-zoom-reset-btn");
  if (resetBtn) resetBtn.textContent = `${Math.round(state.lightboxZoom * 100)}%`;
}

$("lightbox-zoom-in-btn")?.addEventListener("click", () => updateLightboxZoom(state.lightboxZoom + 0.35));
$("lightbox-zoom-out-btn")?.addEventListener("click", () => updateLightboxZoom(state.lightboxZoom - 0.35));
$("lightbox-zoom-reset-btn")?.addEventListener("click", () => updateLightboxZoom(1));
$("lightbox-close-btn")?.addEventListener("click", () => $("image-lightbox-modal")?.classList.add("hidden"));
$("lightbox-stage")?.addEventListener("click", (e) => {
  if (e.target === $("lightbox-stage")) {
    $("image-lightbox-modal")?.classList.add("hidden");
  }
});

// =========================================================================
// Module F: Inline Collaborative Browser Card in Chat
// =========================================================================

async function openOrNavigateBrowserPrompt() {
  const defaultUrl = "https://example.com";
  const url = prompt("输入要在协同浏览器中打开的网址 (留空仅打开当前浏览器面板)：", defaultUrl);
  if (url === null) return;
  try {
    const created = await api("/api/browser/sessions", {
      method: "POST",
      body: JSON.stringify({
        browser_id: state.activeBrowserId || undefined,
        session_id: state.activeSessionId || "global",
        workspace_profile_id: state.activeWorkspaceProfileId || "ws_default",
      }),
    });
    const snap = created.browser || created;
    const browserId = snap.browser_id;
    state.activeBrowserId = browserId;

    if (url.trim()) {
      const navRes = await api(`/api/browser/sessions/${encodeURIComponent(browserId)}/navigate`, {
        method: "POST",
        body: JSON.stringify({ url: url.trim(), actor: "human" }),
      });
      renderOrUpdateBrowserCard(navRes.browser || navRes);
    } else {
      renderOrUpdateBrowserCard(snap);
    }
    switchTab("chat");
    scrollChatBottom(true);
  } catch (err) {
    showToast(`打开浏览器失败: ${err.message}`);
  }
}

$("open-browser-btn")?.addEventListener("click", openOrNavigateBrowserPrompt);
$("composer-browser-btn")?.addEventListener("click", openOrNavigateBrowserPrompt);

function renderOrUpdateBrowserCard(snap, turnId = "") {
  if (!snap || !snap.browser_id) return;
  const browserId = snap.browser_id;
  state.activeBrowserId = browserId;
  const box = $("chat-messages");
  if (!box) return;

  let card = box.querySelector(`.browser-chat-card[data-browser-id="${CSS.escape(browserId)}"]`);
  if (!card) {
    card = document.createElement("div");
    card.className = "browser-chat-card";
    card.dataset.browserId = browserId;
    if (turnId) card.dataset.turnId = turnId;
    card.innerHTML = `
      <div class="browser-card-header">
        <div class="browser-nav-group">
          <button type="button" class="browser-icon-btn" data-bact="back" title="后退">⬅️</button>
          <button type="button" class="browser-icon-btn" data-bact="forward" title="前进">➡️</button>
          <button type="button" class="browser-icon-btn" data-bact="reload" title="刷新">🔄</button>
          <button type="button" class="browser-icon-btn" data-bact="scroll-up" title="向上滚动">⬆️</button>
          <button type="button" class="browser-icon-btn" data-bact="scroll-down" title="向下滚动">⬇️</button>
        </div>
        <form class="browser-url-form">
          <input type="text" class="browser-url-input" placeholder="https://..." />
          <button type="submit" class="browser-icon-btn">前往</button>
        </form>
        <div class="browser-nav-group">
          <button type="button" class="browser-icon-btn" data-bact="zoom" title="全屏放大画面">🔍</button>
          <button type="button" class="browser-control-btn agent" data-bact="control">🤖 AI 操作中</button>
        </div>
      </div>
      <div class="browser-gate-banner hidden"></div>
      <div class="browser-viewport-wrap">
        <img class="browser-viewport-img" alt="Browser Viewport" />
      </div>
      <div class="browser-elements-bar"></div>`;

    // Bind navigation & control events once
    const urlForm = card.querySelector(".browser-url-form");
    const urlInput = card.querySelector(".browser-url-input");
    urlForm.addEventListener("submit", async (e) => {
      e.preventDefault();
      const targetUrl = urlInput.value.trim();
      if (!targetUrl) return;
      try {
        const res = await api(`/api/browser/sessions/${encodeURIComponent(browserId)}/navigate`, {
          method: "POST",
          body: JSON.stringify({ url: targetUrl, actor: "human" }),
        });
        renderOrUpdateBrowserCard(res.browser || res);
      } catch (err) {
        showToast(err.message);
      }
    });

    card.querySelector('[data-bact="back"]').addEventListener("click", () => sendBrowserInput(browserId, { action: "back", actor: "human" }));
    card.querySelector('[data-bact="forward"]').addEventListener("click", () => sendBrowserInput(browserId, { action: "forward", actor: "human" }));
    card.querySelector('[data-bact="reload"]').addEventListener("click", () => sendBrowserInput(browserId, { action: "reload", actor: "human" }));
    card.querySelector('[data-bact="scroll-up"]').addEventListener("click", () => sendBrowserInput(browserId, { action: "scroll", delta_y: -360, actor: "human" }));
    card.querySelector('[data-bact="scroll-down"]').addEventListener("click", () => sendBrowserInput(browserId, { action: "scroll", delta_y: 360, actor: "human" }));

    card.querySelector('[data-bact="zoom"]').addEventListener("click", () => {
      const vpImg = card.querySelector(".browser-viewport-img");
      if (vpImg?.src) openLightbox(vpImg.src, `${snap.title || "协同浏览器"} (${snap.url || ""})`);
    });

    card.querySelector('[data-bact="control"]').addEventListener("click", async () => {
      const curOwner = card.dataset.controlOwner || "agent";
      const nextOwner = curOwner === "human" ? "agent" : "human";
      try {
        const res = await api(`/api/browser/sessions/${encodeURIComponent(browserId)}/control`, {
          method: "POST",
          body: JSON.stringify({
            owner: nextOwner,
            reason: nextOwner === "human" ? "用户在聊天卡片点击真人接管" : "用户交还控制权给 AI",
          }),
        });
        renderOrUpdateBrowserCard(res.browser || res);
        showToast(nextOwner === "human" ? "🖐️ 已切换为真人接管模式" : "🤖 已交还 AI 自动操作");
      } catch (err) {
        showToast(err.message);
      }
    });

    const vpImg = card.querySelector(".browser-viewport-img");
    vpImg.addEventListener("click", (e) => {
      const rect = vpImg.getBoundingClientRect();
      if (!rect.width || !rect.height) return;
      const x = Math.round((e.clientX - rect.left) * (960 / rect.width));
      const y = Math.round((e.clientY - rect.top) * (640 / rect.height));
      sendBrowserInput(browserId, { action: "click", x, y, actor: "human" });
    });

    box.appendChild(card);
  }

  // Update state in card
  card.dataset.controlOwner = snap.control_owner || "agent";
  const urlInput = card.querySelector(".browser-url-input");
  if (urlInput && document.activeElement !== urlInput) {
    urlInput.value = snap.url || "about:blank";
  }
  const backBtn = card.querySelector('[data-bact="back"]');
  const fwdBtn = card.querySelector('[data-bact="forward"]');
  if (backBtn) backBtn.disabled = !snap.can_go_back;
  if (fwdBtn) fwdBtn.disabled = !snap.can_go_forward;

  const ctrlBtn = card.querySelector('[data-bact="control"]');
  if (ctrlBtn) {
    const isHuman = snap.control_owner === "human";
    ctrlBtn.className = `browser-control-btn ${isHuman ? "human" : "agent"}`;
    ctrlBtn.textContent = isHuman ? "🖐️ 真人接管中 (点击交还AI)" : "🤖 AI 操作中 (点击接管)";
  }

  const gateBanner = card.querySelector(".browser-gate-banner");
  if (gateBanner) {
    if (snap.human_required) {
      gateBanner.classList.remove("hidden");
      gateBanner.textContent = `⚠️ ${snap.human_reason || "检测到验证或敏感操作，请真人接管完成后点击交还 AI"}`;
    } else {
      gateBanner.classList.add("hidden");
    }
  }

  const frameB64 = snap.frame_b64 || snap.last_frame_b64 || "";
  const vpImg = card.querySelector(".browser-viewport-img");
  if (vpImg && frameB64) {
    vpImg.src = frameB64.startsWith("data:") ? frameB64 : `data:image/jpeg;base64,${frameB64}`;
  }

  const elsBar = card.querySelector(".browser-elements-bar");
  if (elsBar) {
    elsBar.innerHTML = "";
    const elements = snap.elements || [];
    if (elements.length === 0) {
      elsBar.innerHTML = `<span class="muted small-text">点击上方画面任意位置可直接坐标点击 (960×640)</span>`;
    } else {
      for (const el of elements.slice(0, 24)) {
        const chip = document.createElement("button");
        chip.type = "button";
        chip.className = "browser-el-chip";
        const isInput = ["input", "textarea", "select"].includes(String(el.tag || "").toLowerCase()) && !["submit", "button"].includes(String(el.type || "").toLowerCase());
        chip.innerHTML = `<strong>[${el.id}]</strong> ${escapeHtml((isInput ? "⌨️ " : "") + (el.text || el.placeholder || el.value || el.tag || ""))}`;
        chip.addEventListener("click", () => {
          if (isInput) {
            const val = prompt(`向元素 [${el.id}] (${el.text || el.placeholder || "输入框"}) 输入文本：`, el.value || "");
            if (val !== null) {
              sendBrowserInput(browserId, {
                action: "type",
                element_id: el.id,
                text: val,
                submit: true,
                actor: "human",
              });
            }
          } else {
            sendBrowserInput(browserId, {
              action: "click",
              element_id: el.id,
              actor: "human",
            });
          }
        });
        elsBar.appendChild(chip);
      }
    }
  }
}

async function sendBrowserInput(browserId, payload) {
  try {
    const res = await api(`/api/browser/sessions/${encodeURIComponent(browserId)}/input`, {
      method: "POST",
      body: JSON.stringify(payload),
    });
    renderOrUpdateBrowserCard(res.browser || res);
  } catch (err) {
    showToast(err.message);
  }
}

// =========================================================================
// Module D: Agent Team Status Card in Chat
// =========================================================================

function renderOrUpdateAgentTeamCard(data, turnId = "") {
  const box = $("chat-messages");
  if (!box) return;
  const teamId = data.team_id || turnId || "active_team";
  let card = box.querySelector(`.agent-team-card[data-team-id="${CSS.escape(teamId)}"]`);
  if (!card) {
    card = document.createElement("div");
    card.className = "agent-team-card";
    card.dataset.teamId = teamId;
    if (turnId) card.dataset.turnId = turnId;
    card.innerHTML = `
      <div class="agent-team-header">
        <span>🤝 子智能体协作团队 (Agent Team)</span>
        <span class="muted small-text agent-team-summary"></span>
      </div>
      <div class="agent-team-list"></div>`;
    box.appendChild(card);
  }

  const agents = data.agents || data.members || (data.agent ? [data.agent] : []);
  const summaryEl = card.querySelector(".agent-team-summary");
  if (summaryEl) {
    const runningCount = agents.filter((a) => a.status === "running").length;
    summaryEl.textContent = runningCount > 0 ? `${runningCount} 个子代理运行中` : `共 ${agents.length} 个子代理`;
  }

  const listEl = card.querySelector(".agent-team-list");
  if (!listEl) return;
  listEl.innerHTML = "";

  for (const ag of agents) {
    const row = document.createElement("div");
    row.className = "agent-member-row";
    const status = ag.status || "running";
    const costStr = ag.cost !== undefined ? ` · ¥${Number(ag.cost || 0).toFixed(4)}` : "";
    const roundsStr = ag.rounds !== undefined ? ` · ${ag.rounds} 轮` : "";
    row.innerHTML = `
      <div class="agent-member-info">
        <div class="agent-member-title">
          <span>🤖 ${escapeHtml(ag.role || ag.name || ag.agent_id || "SubAgent")}</span>
          <span class="agent-status-badge ${escapeHtml(status)}">${escapeHtml(status)}</span>
        </div>
        <div class="agent-member-sub">
          模型: ${escapeHtml(ag.model || "deepseek-chat")}${escapeHtml(roundsStr)}${escapeHtml(costStr)}
          ${ag.task ? ` · 任务: ${escapeHtml(String(ag.task).slice(0, 60))}` : ""}
        </div>
      </div>`;

    if (status === "running" && ag.agent_id) {
      const cancelBtn = document.createElement("button");
      cancelBtn.type = "button";
      cancelBtn.className = "btn small danger-outline";
      cancelBtn.textContent = "取消";
      cancelBtn.addEventListener("click", async () => {
        cancelBtn.disabled = true;
        try {
          await api(
            `/api/sessions/${state.activeSessionId}/agents/${encodeURIComponent(ag.agent_id)}/cancel`,
            { method: "POST" }
          );
          showToast(`已取消子代理 ${ag.role || ag.agent_id}`);
        } catch (err) {
          cancelBtn.disabled = false;
          showToast(err.message);
        }
      });
      row.appendChild(cancelBtn);
    }

    listEl.appendChild(row);
  }
}

// =========================================================================
// Module E: API Wallet Panel in Settings
// =========================================================================

async function refreshWalletSummary(forceBalance = false) {
  try {
    if (forceBalance) {
      await api("/api/wallet/balance?force=true").catch(() => {});
    }
    const summary = await api("/api/wallet/summary");
    state.walletSummary = summary;
    renderWalletSummaryUI(summary);
  } catch (err) {
    if (forceBalance) showToast(`刷新钱包失败: ${err.message}`);
  }
}

function renderWalletSummaryUI(s) {
  if (!s || !$("wallet-card")) return;
  const bal = s.balance || {};
  const today = s.today || {};
  const hour = s.current_hour || {};
  const rules = s.rules || {};
  if ($("wallet-updated-label")) {
    $("wallet-updated-label").textContent = bal.updated_at ? `更新于 ${bal.updated_at}` : "实时统计 Token 与费用";
  }

  if (bal.available && bal.total_balance !== null && bal.total_balance !== undefined) {
    $("wallet-balance-val").textContent = `¥${Number(bal.total_balance).toFixed(2)}`;
    const srcLabel = bal.source === "api" ? "官方 API" : bal.source === "manual_estimated" ? "手动估算" : bal.source;
    $("wallet-balance-sub").textContent = `来源: ${srcLabel}${bal.stale ? " (缓存)" : ""}`;
  } else {
    $("wallet-balance-val").textContent = "未启用";
    $("wallet-balance-sub").textContent = "可设置手动初始余额估算";
  }

  $("wallet-today-cost").textContent = `¥${Number(today.cost || 0).toFixed(4)}`;
  $("wallet-today-tokens").textContent = `${Number(today.total_tokens || 0).toLocaleString()} Tokens · ${today.turns || 0} 轮`;

  $("wallet-hour-cost").textContent = `¥${Number(hour.cost || 0).toFixed(4)}`;
  $("wallet-hour-tokens").textContent = `${hour.hour || "--:00"} · ${Number(hour.total_tokens || 0).toLocaleString()} Tokens`;

  const banner = $("wallet-downgrade-banner");
  if (banner) {
    if (s.downgrade_active) {
      banner.classList.remove("hidden");
      $("wallet-downgrade-text").textContent = `⚡ 自动降级生效中: ${s.downgrade_reason || "触发低额保护"} → ${rules.fallback_profile_id || "deepseek-flash"}`;
    } else {
      banner.classList.add("hidden");
    }
  }

  const breakdownEl = $("wallet-models-breakdown");
  if (breakdownEl) {
    breakdownEl.innerHTML = "";
    const byModel = today.by_model || [];
    for (const m of byModel) {
      const row = document.createElement("div");
      row.className = "wallet-model-row";
      row.innerHTML = `<span>${escapeHtml(m.model)} (${m.turns}轮)</span><span>${Number(m.total_tokens || 0).toLocaleString()} tok · <strong>¥${Number(m.cost || 0).toFixed(4)}</strong></span>`;
      breakdownEl.appendChild(row);
    }
  }

  // Populate rules form
  $("wallet-rule-enabled").checked = rules.enabled !== false;
  $("wallet-rule-balance-below").value = rules.balance_below ?? 5.0;
  $("wallet-rule-daily-above").value = rules.daily_spend_above ?? 20.0;
  $("wallet-rule-fallback").value = rules.fallback_profile_id || "deepseek-flash";
  $("wallet-rule-manual-balance").value = rules.manual_balance !== null && rules.manual_balance !== undefined ? rules.manual_balance : "";
  $("wallet-rule-bark").checked = rules.notify_bark !== false;
}

$("wallet-refresh-btn")?.addEventListener("click", () => refreshWalletSummary(true));

$("wallet-reset-downgrade-btn")?.addEventListener("click", async () => {
  try {
    await api("/api/wallet/rules", {
      method: "PUT",
      body: JSON.stringify(state.walletSummary?.rules || {}),
    });
    await refreshWalletSummary();
    showToast("已重置自动降级状态");
  } catch (err) {
    showToast(err.message);
  }
});

$("save-wallet-rules-btn")?.addEventListener("click", async () => {
  const manualRaw = $("wallet-rule-manual-balance").value.trim();
  const payload = {
    enabled: $("wallet-rule-enabled").checked,
    balance_below: parseFloat($("wallet-rule-balance-below").value || "5"),
    daily_spend_above: parseFloat($("wallet-rule-daily-above").value || "20"),
    fallback_profile_id: $("wallet-rule-fallback").value.trim() || "deepseek-flash",
    manual_balance: manualRaw === "" ? null : parseFloat(manualRaw),
    notify_bark: $("wallet-rule-bark").checked,
  };
  try {
    await api("/api/wallet/rules", {
      method: "PUT",
      body: JSON.stringify(payload),
    });
    $("wallet-rules-status").textContent = "规则已保存";
    await refreshWalletSummary();
    showToast("钱包与自动降级规则已保存");
  } catch (err) {
    showToast(err.message);
  }
});

// --- Pending Approvals & Interactions ---

function renderPendingBox(summary) {
  const box = $("pending-box");
  const approvals = (summary.pending_approvals || []).filter(
    (r) => !state.resolvingIds.has(r.request_id)
  );
  const interactions = (summary.pending_interactions || []).filter(
    (r) => !state.resolvingIds.has(r.request_id)
  );

  if (approvals.length === 0 && interactions.length === 0) {
    box.innerHTML = "";
    box.classList.add("hidden");
    return;
  }
  box.classList.remove("hidden");

  let batchBar = box.querySelector(".batch-bar");
  if (approvals.length > 1) {
    if (!batchBar) {
      batchBar = document.createElement("div");
      batchBar.className = "batch-bar";
      box.prepend(batchBar);
    }
    batchBar.innerHTML = `
      <span class="small-text"><strong>待审批 (${approvals.length} 项)</strong></span>
      <div class="row-gap">
        <button class="btn primary small" data-batch="allow">全部允许</button>
        <button class="btn small" data-batch="auto">全部允许并转自动</button>
        <button class="btn danger small" data-batch="deny">全部拒绝</button>
      </div>`;
    batchBar.querySelector('[data-batch="allow"]').addEventListener("click", (e) => {
      e.currentTarget.disabled = true;
      submitApproval("all", true);
    });
    batchBar.querySelector('[data-batch="auto"]').addEventListener("click", (e) => {
      e.currentTarget.disabled = true;
      submitApproval("all", true, "auto");
    });
    batchBar.querySelector('[data-batch="deny"]').addEventListener("click", (e) => {
      e.currentTarget.disabled = true;
      submitApproval("all", false);
    });
  } else if (batchBar) {
    batchBar.remove();
  }

  const activeIds = new Set([
    ...approvals.map((a) => `app-${a.request_id}`),
    ...interactions.map((i) => `int-${i.request_id}`),
  ]);
  box.querySelectorAll(".pending-item").forEach((el) => {
    if (!activeIds.has(el.dataset.domId)) {
      el.remove();
    }
  });

  for (const req of approvals) {
    const domId = `app-${req.request_id}`;
    if (box.querySelector(`[data-dom-id="${domId}"]`)) continue;

    const wrap = document.createElement("div");
    wrap.className = "pending-item";
    wrap.dataset.domId = domId;
    wrap.innerHTML = `<strong>⚠️ 需要审批: ${escapeHtml(req.tool_name)}</strong>
      <pre style="margin:6px 0;white-space:pre-wrap;font-size:12px;">${escapeHtml(JSON.stringify(req.args || {}, null, 2))}</pre>
      <div class="row-gap" style="flex-wrap:wrap">
        <button class="btn primary small" data-act="allow">允许执行</button>
        <button class="btn small" data-act="auto">允许并转自动</button>
        <button class="btn danger small" data-act="deny">拒绝</button>
      </div>`;
    const btns = wrap.querySelectorAll("button");
    const lockButtons = (clicked) => {
      btns.forEach((b) => (b.disabled = true));
      clicked.textContent = "处理中...";
    };
    wrap.querySelector('[data-act="allow"]').addEventListener("click", (e) => {
      lockButtons(e.currentTarget);
      submitApproval(req.request_id, true);
    });
    wrap.querySelector('[data-act="auto"]').addEventListener("click", (e) => {
      lockButtons(e.currentTarget);
      submitApproval(req.request_id, true, "auto");
    });
    wrap.querySelector('[data-act="deny"]').addEventListener("click", (e) => {
      lockButtons(e.currentTarget);
      submitApproval(req.request_id, false);
    });
    box.appendChild(wrap);
  }

  for (const inter of interactions) {
    const domId = `int-${inter.request_id}`;
    if (box.querySelector(`[data-dom-id="${domId}"]`)) continue;

    const q = (inter.questions || [])[0];
    if (!q) continue;
    const wrap = document.createElement("div");
    wrap.className = "pending-item";
    wrap.dataset.domId = domId;
    wrap.innerHTML = `<strong>❓ ${escapeHtml(q.question)}</strong>`;
    const optsWrap = document.createElement("div");
    optsWrap.className = "row-gap";
    optsWrap.style.flexWrap = "wrap";
    optsWrap.style.marginTop = "6px";
    for (const opt of q.options || []) {
      const b = document.createElement("button");
      b.className = "btn small";
      b.textContent = opt.text;
      b.addEventListener("click", () => {
        wrap.querySelectorAll("button").forEach((btn) => (btn.disabled = true));
        b.textContent = "提交中...";
        submitInteraction(inter.request_id, [
          { selected_option_ids: [opt.id], freeform_response: opt.text },
        ]);
      });
      optsWrap.appendChild(b);
    }
    const freeRow = document.createElement("div");
    freeRow.className = "row-gap";
    freeRow.style.marginTop = "6px";
    freeRow.innerHTML = `<input type="text" placeholder="或输入自定义回答..." style="flex:1" />
      <button class="btn primary small">提交</button>`;
    freeRow.querySelector("button").addEventListener("click", (e) => {
      const val = freeRow.querySelector("input").value.trim();
      wrap.querySelectorAll("button").forEach((btn) => (btn.disabled = true));
      e.currentTarget.textContent = "提交中...";
      submitInteraction(inter.request_id, [{ freeform_response: val }]);
    });
    wrap.append(optsWrap, freeRow);
    box.appendChild(wrap);
  }
}

async function submitApproval(requestId, allow, setApprovalMode = null) {
  if (requestId !== "all") {
    state.resolvingIds.add(requestId);
  }
  try {
    const payload = { allow };
    if (setApprovalMode) payload.set_approval_mode = setApprovalMode;
    const res = await api(`/api/sessions/${state.activeSessionId}/approvals/${requestId}`, {
      method: "POST",
      body: JSON.stringify(payload),
    });
    if (setApprovalMode === "auto") {
      showToast("已切换当前会话为自动执行模式");
    }
    if (res.session) {
      updateSessionMeta(res.session);
    } else {
      await refreshActiveSummary();
    }
  } catch (err) {
    state.resolvingIds.delete(requestId);
    await refreshActiveSummary();
    showToast(err.message);
  }
}

async function submitInteraction(requestId, responses) {
  state.resolvingIds.add(requestId);
  try {
    const res = await api(`/api/sessions/${state.activeSessionId}/interactions/${requestId}`, {
      method: "POST",
      body: JSON.stringify({ responses, cancelled: false }),
    });
    if (res.session) {
      updateSessionMeta(res.session);
    } else {
      await refreshActiveSummary();
    }
  } catch (err) {
    state.resolvingIds.delete(requestId);
    await refreshActiveSummary();
    showToast(err.message);
  }
}

async function sendPrompt() {
  if (state.sendingPrompt) return;
  const input = $("chat-input");
  const rawPrompt = input.value.trim();
  const attachmentIds = state.pendingAttachments.map((a) => a.att_id).filter(Boolean);
  if ((!rawPrompt && attachmentIds.length === 0) || !state.activeSessionId) return;

  const prompt = rawPrompt || "请查看并分析所附图片";
  const prevAttachments = [...state.pendingAttachments];

  state.sendingPrompt = true;
  $("send-btn").disabled = true;
  input.value = "";
  autoGrow(input);
  state.pendingAttachments = [];
  renderPendingAttachments();

  try {
    const res = await api(`/api/sessions/${state.activeSessionId}/message`, {
      method: "POST",
      body: JSON.stringify({
        prompt,
        model: $("quick-model-select").value,
        attachments: attachmentIds,
      }),
    });
    if (res.session) updateSessionMeta(res.session);
  } catch (err) {
    input.value = rawPrompt;
    autoGrow(input);
    state.pendingAttachments = prevAttachments;
    renderPendingAttachments();
    showToast(err.message);
  } finally {
    state.sendingPrompt = false;
    $("send-btn").disabled = false;
  }
}

$("send-btn").addEventListener("click", sendPrompt);
$("chat-input").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    sendPrompt();
  }
});
$("chat-input").addEventListener("input", () => autoGrow($("chat-input")));

$("cancel-btn").addEventListener("click", async () => {
  const res = await api(`/api/sessions/${state.activeSessionId}/cancel`, { method: "POST" });
  if (res.session) updateSessionMeta(res.session);
  showToast("已请求停止");
});

$("new-session-btn").addEventListener("click", async () => {
  const created = await api("/api/sessions", {
    method: "POST",
    body: JSON.stringify({
      workspace: state.workspace,
      workspace_profile_id: state.activeWorkspaceProfileId,
      title: "New Session",
      model: $("quick-model-select").value,
    }),
  });
  state.sessions.unshift(created);
  await selectSession(created.session_id);
  switchTab("chat");
});

$("session-drawer-btn").addEventListener("click", () => $("session-drawer").classList.remove("hidden"));
$("close-drawer-btn").addEventListener("click", closeDrawer);
$("drawer-backdrop").addEventListener("click", closeDrawer);
function closeDrawer() {
  $("session-drawer").classList.add("hidden");
}

function autoGrow(el) {
  el.style.height = "auto";
  el.style.height = `${Math.min(el.scrollHeight, 120)}px`;
}

// --- Files & Mobile CodeMirror 6 Editor ---

async function loadDirectory(relPath) {
  state.currentDir = relPath;
  const qs = new URLSearchParams({ workspace: state.workspace, path: relPath });
  const data = await api(`/api/files/tree?${qs}`);
  renderBreadcrumbs(relPath);
  renderEntries(data.entries || []);
}

function renderBreadcrumbs(relPath) {
  const bc = $("files-breadcrumb");
  bc.innerHTML = "";
  const rootSpan = document.createElement("span");
  rootSpan.className = "crumb";
  rootSpan.textContent = "工作区";
  rootSpan.addEventListener("click", () => loadDirectory(""));
  bc.appendChild(rootSpan);

  if (!relPath) return;
  const parts = relPath.split("/").filter(Boolean);
  let acc = "";
  for (const part of parts) {
    acc = acc ? `${acc}/${part}` : part;
    const sep = document.createElement("span");
    sep.textContent = "/";
    const span = document.createElement("span");
    span.className = "crumb";
    span.textContent = part;
    const target = acc;
    span.addEventListener("click", () => loadDirectory(target));
    bc.append(sep, span);
  }
}

function renderEntries(entries) {
  const list = $("files-list");
  list.innerHTML = "";
  if (state.currentDir) {
    const parent = state.currentDir.split("/").slice(0, -1).join("/");
    const upRow = document.createElement("div");
    upRow.className = "file-row";
    upRow.innerHTML = `<div class="file-row-main"><span>↩️</span><span class="file-name">.. (上一级)</span></div>`;
    upRow.addEventListener("click", () => loadDirectory(parent));
    list.appendChild(upRow);
  }

  for (const entry of entries) {
    const row = document.createElement("div");
    row.className = "file-row";
    const main = document.createElement("div");
    main.className = "file-row-main";
    const ico = entry.is_dir ? "📁" : "📄";
    const sizeText = entry.is_dir ? "目录" : formatBytes(entry.size);
    main.innerHTML = `<span>${ico}</span>
      <div style="min-width:0;flex:1">
        <div class="file-name"></div>
        <div class="file-meta">${sizeText}</div>
      </div>`;
    main.querySelector(".file-name").textContent = entry.name;
    main.addEventListener("click", () => {
      if (entry.is_dir) loadDirectory(entry.path);
      else openFileInEditor(entry.path);
    });

    const renameBtn = document.createElement("button");
    renameBtn.className = "btn small";
    renameBtn.textContent = "改名";
    renameBtn.addEventListener("click", async () => {
      const next = prompt("重命名/移动为（相对工作区路径）：", entry.path);
      if (!next || next.trim() === entry.path) return;
      await api("/api/files/rename", {
        method: "POST",
        body: JSON.stringify({
          workspace: state.workspace,
          old_path: entry.path,
          new_path: next.trim(),
        }),
      });
      await loadDirectory(state.currentDir);
      showToast("已重命名");
    });

    const delBtn = document.createElement("button");
    delBtn.className = "btn small danger-outline";
    delBtn.textContent = "删";
    delBtn.addEventListener("click", async () => {
      if (!confirm(`确认删除 ${entry.path} ?`)) return;
      const qs = new URLSearchParams({ workspace: state.workspace, path: entry.path });
      await api(`/api/files/delete?${qs}`, { method: "DELETE" });
      await loadDirectory(state.currentDir);
      showToast("已删除");
    });

    row.append(main, renameBtn, delBtn);
    list.appendChild(row);
  }
}

let searchTimer = null;
$("file-search-input").addEventListener("input", (e) => {
  clearTimeout(searchTimer);
  const q = e.target.value.trim();
  if (!q) {
    loadDirectory(state.currentDir);
    return;
  }
  searchTimer = setTimeout(async () => {
    const qs = new URLSearchParams({ workspace: state.workspace, q });
    const data = await api(`/api/files/search?${qs}`);
    const list = $("files-list");
    list.innerHTML = "";
    for (const m of data.matches || []) {
      const row = document.createElement("div");
      row.className = "file-row";
      const main = document.createElement("div");
      main.className = "file-row-main";
      main.innerHTML = `<span>🔍</span>
        <div style="min-width:0;flex:1">
          <div class="file-name"></div>
          <div class="file-meta"></div>
        </div>`;
      main.querySelector(".file-name").textContent = m.line ? `${m.path}:${m.line}` : m.path;
      main.querySelector(".file-meta").textContent = m.preview || "";
      main.addEventListener("click", () => openFileInEditor(m.path));
      row.appendChild(main);
      list.appendChild(row);
    }
  }, 280);
});

$("new-file-btn").addEventListener("click", async () => {
  const name = prompt("输入新文件名（相对当前目录）：");
  if (!name) return;
  const rel = state.currentDir ? `${state.currentDir}/${name}` : name;
  await api("/api/files/create", {
    method: "POST",
    body: JSON.stringify({ workspace: state.workspace, path: rel, is_dir: false, content: "" }),
  });
  await loadDirectory(state.currentDir);
  await openFileInEditor(rel);
});

$("new-dir-btn").addEventListener("click", async () => {
  const name = prompt("输入新目录名：");
  if (!name) return;
  const rel = state.currentDir ? `${state.currentDir}/${name}` : name;
  await api("/api/files/create", {
    method: "POST",
    body: JSON.stringify({ workspace: state.workspace, path: rel, is_dir: true }),
  });
  await loadDirectory(state.currentDir);
});

async function loadCodeMirrorModules() {
  if (!state.cmPromise) {
    state.cmPromise = Promise.all([
      import("https://esm.sh/codemirror@6.0.1"),
      import("https://esm.sh/@codemirror/view@6.35.0"),
      import("https://esm.sh/@codemirror/state@6.4.1"),
      import("https://esm.sh/@codemirror/lang-python@6.1.6"),
      import("https://esm.sh/@codemirror/lang-javascript@6.2.2"),
      import("https://esm.sh/@codemirror/lang-json@6.0.1"),
      import("https://esm.sh/@codemirror/lang-markdown@6.3.1"),
    ]).catch(() => null);
  }
  return state.cmPromise;
}

async function openFileInEditor(relPath) {
  const qs = new URLSearchParams({ workspace: state.workspace, path: relPath });
  const data = await api(`/api/files/read?${qs}`);
  if (data.is_binary) {
    showToast("二进制文件暂不支持文本编辑");
    return;
  }
  if (data.too_large) {
    showToast("文件过大 (>1.5MB)，跳过在线编辑");
    return;
  }

  $("files-browser-pane").classList.add("hidden");
  $("file-editor-pane").classList.remove("hidden");
  $("editor-filepath").textContent = relPath;
  $("editor-save-btn").disabled = true;
  $("mention-open-file-btn").classList.remove("hidden");
  $("mention-open-file-btn").textContent = `@ ${relPath.split("/").pop()}`;

  const host = $("editor-host");
  host.innerHTML = "";
  const cmMods = await loadCodeMirrorModules();

  if (cmMods) {
    const [cm, viewMod, _stateMod, pyMod, jsMod, jsonMod, mdMod] = cmMods;
    const ext = data.ext || "";
    const langExts = [];
    if (ext === ".py") langExts.push(pyMod.python());
    else if ([".js", ".mjs", ".ts", ".tsx", ".jsx"].includes(ext))
      langExts.push(jsMod.javascript({ typescript: ext.includes("ts") }));
    else if (ext === ".json") langExts.push(jsonMod.json());
    else if (ext === ".md") langExts.push(mdMod.markdown());

    const view = new cm.EditorView({
      doc: data.content,
      extensions: [
        cm.basicSetup,
        viewMod.EditorView.lineWrapping,
        ...langExts,
        viewMod.EditorView.updateListener.of((u) => {
          if (u.docChanged && state.openFile) {
            markEditorDirty(true);
          }
        }),
      ],
      parent: host,
    });
    state.openFile = {
      path: relPath,
      mtime: data.mtime,
      dirty: false,
      editorType: "cm",
      cmView: view,
      textarea: null,
    };
  } else {
    const ta = document.createElement("textarea");
    ta.className = "fallback-editor";
    ta.value = data.content;
    ta.spellcheck = false;
    ta.addEventListener("input", () => markEditorDirty(true));
    host.appendChild(ta);
    state.openFile = {
      path: relPath,
      mtime: data.mtime,
      dirty: false,
      editorType: "textarea",
      cmView: null,
      textarea: ta,
    };
  }
}

function markEditorDirty(dirty) {
  if (!state.openFile) return;
  state.openFile.dirty = dirty;
  $("editor-save-btn").disabled = !dirty;
  $("editor-filepath").textContent = `${dirty ? "● " : ""}${state.openFile.path}`;
}

function getEditorText() {
  if (!state.openFile) return "";
  if (state.openFile.cmView) return state.openFile.cmView.state.doc.toString();
  return state.openFile.textarea?.value || "";
}

$("symbol-bar").addEventListener("click", (e) => {
  const btn = e.target.closest("button[data-ins]");
  if (!btn || !state.openFile) return;
  const ins = btn.dataset.ins;
  if (state.openFile.cmView) {
    const view = state.openFile.cmView;
    const sel = view.state.selection.main;
    view.dispatch({
      changes: { from: sel.from, to: sel.to, insert: ins },
      selection: { anchor: sel.from + ins.length },
    });
    view.focus();
  } else if (state.openFile.textarea) {
    const ta = state.openFile.textarea;
    const start = ta.selectionStart;
    const end = ta.selectionEnd;
    ta.value = ta.value.slice(0, start) + ins + ta.value.slice(end);
    ta.selectionStart = ta.selectionEnd = start + ins.length;
    ta.focus();
    markEditorDirty(true);
  }
});

async function saveCurrentFile(force = false) {
  if (!state.openFile) return;
  try {
    const res = await api("/api/files/write", {
      method: "PUT",
      body: JSON.stringify({
        workspace: state.workspace,
        path: state.openFile.path,
        content: getEditorText(),
        expected_mtime: state.openFile.mtime,
        force,
      }),
    });
    state.openFile.mtime = res.mtime;
    markEditorDirty(false);
    showToast("文件已保存");
  } catch (err) {
    if (err.status === 409) {
      if (confirm("该文件在电脑端被外部/Agent修改过。点击确定强制覆盖，取消则保留当前编辑。")) {
        await saveCurrentFile(true);
      }
    } else {
      showToast(err.message);
    }
  }
}

$("editor-save-btn").addEventListener("click", () => saveCurrentFile(false));

function closeEditorPane(skipPrompt = false) {
  if (!skipPrompt && state.openFile?.dirty && !confirm("当前修改尚未保存，确定返回文件列表？")) {
    return;
  }
  if (state.openFile?.cmView) state.openFile.cmView.destroy();
  state.openFile = null;
  $("file-editor-pane").classList.add("hidden");
  $("files-browser-pane").classList.remove("hidden");
}

$("editor-back-btn").addEventListener("click", () => closeEditorPane(false));

function insertFileReferenceToChat() {
  if (!state.openFile) return;
  const input = $("chat-input");
  const ref = `请查看或修改工作区文件 \`${state.openFile.path}\`：`;
  input.value = input.value ? `${input.value.trimEnd()}\n${ref}` : ref;
  autoGrow(input);
  switchTab("chat");
  input.focus();
}

$("editor-ref-btn").addEventListener("click", insertFileReferenceToChat);
$("mention-open-file-btn").addEventListener("click", insertFileReferenceToChat);

// --- Git Diff & Settings ---

async function refreshGitStatus(filePath = null) {
  if (!state.workspace) return;
  const qs = new URLSearchParams({ workspace: state.workspace });
  if (filePath) qs.set("path", filePath);
  const data = await api(`/api/git/status?${qs}`);
  if (!data.is_git_repo) {
    $("git-branch-label").textContent = data.message || "当前工作区尚未初始化 Git 仓库";
    $("git-files-list").innerHTML = "";
    $("git-diff-view").textContent = "💡 提示：该目录尚无 .git 仓库。在终端运行 git init 或切换到含 Git 的工作区后即可查看变更审查。";
    return;
  }
  $("git-branch-label").textContent = `分支: ${data.branch || "HEAD"} · ${data.files.length} 个变更`;
  const list = $("git-files-list");
  list.innerHTML = "";

  const allPill = document.createElement("button");
  allPill.className = "git-file-pill";
  allPill.textContent = "全部变更";
  allPill.addEventListener("click", () => refreshGitStatus(null));
  list.appendChild(allPill);

  for (const f of data.files) {
    const pill = document.createElement("button");
    pill.className = "git-file-pill";
    pill.textContent = `${f.status} ${f.path}`;
    pill.addEventListener("click", () => refreshGitStatus(f.path));
    list.appendChild(pill);
  }

  renderDiffText(data.diff || "(工作区无未提交的文本 diff)");
}

function renderDiffText(diff) {
  const pre = $("git-diff-view");
  pre.innerHTML = "";
  for (const line of diff.split("\n")) {
    const span = document.createElement("div");
    if (line.startsWith("+") && !line.startsWith("+++")) span.className = "diff-add";
    else if (line.startsWith("-") && !line.startsWith("---")) span.className = "diff-del";
    else if (line.startsWith("@@")) span.className = "diff-hunk";
    span.textContent = line;
    pre.appendChild(span);
  }
}

$("git-refresh-btn").addEventListener("click", () => refreshGitStatus());
$("git-ask-review-btn").addEventListener("click", () => {
  $("chat-input").value = "请调用 git_status_diff 检查当前工作区改动，总结内容并指出潜在 bug 或风险。";
  autoGrow($("chat-input"));
  switchTab("chat");
});

function populateSettingsUI(s) {
  $("set-workspaces").value = (s.workspaces || []).join("\n");
  $("set-approval-mode").value = s.default_approval_mode || "ask_commands";
  $("set-bark-url").value = s.bark_url || "";
  $("set-base-url").value = s.deepseek_base_url || "https://api.deepseek.com";
  $("set-model").value = s.model || "deepseek-chat";
  $("set-api-key").value = "";
  $("settings-status").textContent = s.has_api_key
    ? "DeepSeek API Key 已配置"
    : "未配置 DeepSeek API Key，请填入后保存";
}

$("save-settings-btn").addEventListener("click", async () => {
  const workspaces = $("set-workspaces")
    .value.split("\n")
    .map((l) => l.trim())
    .filter(Boolean);
  const payload = {
    workspaces,
    default_approval_mode: $("set-approval-mode").value,
    bark_url: $("set-bark-url").value.trim(),
    deepseek_base_url: $("set-base-url").value.trim(),
    model: $("set-model").value.trim(),
  };
  const key = $("set-api-key").value.trim();
  if (key) payload.deepseek_api_key = key;
  try {
    const updated = await api("/api/settings", {
      method: "PUT",
      body: JSON.stringify(payload),
    });
    state.settings = updated;
    populateSettingsUI(updated);
    populateWorkspaces(updated.workspaces);
    syncQuickModelSelect(updated.model || "deepseek-chat");
    showToast("设置已保存");
  } catch (err) {
    showToast(err.message);
  }
});

$("logout-btn").addEventListener("click", handleUnauthorized);

function formatBytes(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

function escapeHtml(str) {
  return String(str)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

boot();
