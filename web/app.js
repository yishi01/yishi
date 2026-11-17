const TOKEN_KEY = "agy_mobile_token";
const ACTIVE_SESSION_KEY = "agy_mobile_session_id";
const ACTIVE_WS_KEY = "agy_mobile_workspace";

const state = {
  token: localStorage.getItem(TOKEN_KEY) || "",
  settings: null,
  workspace: localStorage.getItem(ACTIVE_WS_KEY) || "",
  sessions: [],
  activeSessionId: localStorage.getItem(ACTIVE_SESSION_KEY) || "",
  lastSeq: 0,
  ws: null,
  wsSynced: false,
  reconnectTimer: null,
  currentTurn: null,
  scrollRaf: null,
  resolvingIds: new Set(),
  sendingPrompt: false,
  currentDir: "",
  openFile: null, // { path, mtime, dirty, editorType, cmView, textarea }
  cmPromise: null,
};

const $ = (id) => document.getElementById(id);

function showToast(msg) {
  const el = $("toast");
  el.textContent = msg;
  el.classList.remove("hidden");
  clearTimeout(showToast._t);
  showToast._t = setTimeout(() => el.classList.add("hidden"), 2600);
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
    const err = new Error(data.detail || `请求失败 (HTTP ${resp.status})`);
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
  // 1. Extract inline code spans `...` first so inner symbols (*, _) are untouched
  let out = escapedLine.replace(/`([^`\n]+)`/g, (_m, code) => {
    const idx = inlineCodes.length;
    inlineCodes.push(`<code class="md-inline-code">${code}</code>`);
    return `\u0000INLINECODE_${idx}\u0000`;
  });

  // 2. Links [text](https://...)
  out = out.replace(
    /\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g,
    '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>'
  );

  // 3. Bold **text** or __text__
  out = out.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  out = out.replace(/__([^_]+)__/g, "<strong>$1</strong>");

  // 4. Italic *text* (avoiding math/bullet collisions)
  out = out.replace(/(^|[\s(])\*([^*\n]+)\*(?=[\s).,!?:;]|$)/g, "$1<em>$2</em>");

  // 5. Strikethrough ~~text~~
  out = out.replace(/~~([^~]+)~~/g, "<del>$1</del>");

  // 6. Restore inline code spans
  out = out.replace(/\u0000INLINECODE_(\d+)\u0000/g, (_m, i) => inlineCodes[Number(i)] || "");
  return out;
}

function renderMarkdown(rawText) {
  const cleaned = normalizeCleanText(rawText);
  if (!cleaned.trim()) return "";

  const codeBlocks = [];
  const inlineCodes = [];

  // Extract fenced code blocks (including unclosed trailing block during streaming)
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

    // Code block placeholder
    const cbMatch = trimmed.match(/^\u0000CODEBLOCK_(\d+)\u0000$/);
    if (cbMatch) {
      htmlParts.push(codeBlocks[Number(cbMatch[1])] || "");
      i++;
      continue;
    }

    // Horizontal rule
    if (/^(?:---|\*\*\*|___)\s*$/.test(trimmed)) {
      htmlParts.push("<hr />");
      i++;
      continue;
    }

    // Heading # .. ######
    const hMatch = trimmed.match(/^(#{1,6})\s+(.+)$/);
    if (hMatch) {
      const level = Math.min(4, hMatch[1].length);
      const content = renderInlineMarkdown(escapeHtml(hMatch[2].trim()), inlineCodes);
      htmlParts.push(`<h${level}>${content}</h${level}>`);
      i++;
      continue;
    }

    // Table | a | b |
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
      i += 2; // Skip header & separator
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

    // Blockquote >
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

    // Unordered list - or * or •
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

    // Ordered list 1.
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

    // Regular paragraph (merge consecutive normal lines)
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
  populateSettingsUI(settings);
  populateWorkspaces(settings.workspaces);
  syncQuickModelSelect(settings.model || "deepseek-chat");
  await loadSessions();
  await loadDirectory("");
  await refreshGitStatus();
}

function syncQuickModelSelect(modelName) {
  const sel = $("quick-model-select");
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
  showToast("已切换工作区");
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
  if (tabName === "git") refreshGitStatus();
}

// --- Sessions & WebSocket Cursor Sync ---

async function loadSessions() {
  const data = await api("/api/sessions");
  state.sessions = data.sessions || [];
  if (state.sessions.length === 0) {
    const created = await api("/api/sessions", {
      method: "POST",
      body: JSON.stringify({
        workspace: state.workspace,
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
  list.innerHTML = "";
  for (const s of state.sessions) {
    const item = document.createElement("div");
    item.className = `session-item ${s.session_id === state.activeSessionId ? "active" : ""}`;
    const meta = document.createElement("div");
    meta.className = "session-meta";
    meta.innerHTML = `<div class="session-title"></div><div class="session-sub">${escapeHtml(s.model || "deepseek-chat")} · ${escapeHtml(s.status)}</div>`;
    meta.querySelector(".session-title").textContent = s.title;
    meta.addEventListener("click", async () => {
      closeDrawer();
      await selectSession(s.session_id);
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
    item.append(meta, del);
    list.appendChild(item);
  }
}

async function selectSession(sessionId) {
  state.activeSessionId = sessionId;
  localStorage.setItem(ACTIVE_SESSION_KEY, sessionId);
  state.lastSeq = 0;
  state.currentTurn = null;
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

function connectSessionSocket(reset = false) {
  if (state.ws) {
    state.ws.onclose = null;
    state.ws.close();
  }
  clearTimeout(state.reconnectTimer);
  if (!state.activeSessionId || !state.token) return;

  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  const after = reset ? 0 : state.lastSeq;
  const wsUrl = `${proto}//${location.host}/ws/sessions/${state.activeSessionId}?token=${encodeURIComponent(state.token)}&after_seq=${after}`;
  setConnStatus("reconnecting", "同步中...");

  const ws = new WebSocket(wsUrl);
  state.ws = ws;
  state.wsSynced = false;

  ws.onopen = () => {
    setConnStatus("online", "已连接");
  };

  ws.onmessage = (evt) => {
    const msg = JSON.parse(evt.data);
    if (msg.type === "ping") return;
    if (msg.type === "sync_complete") {
      state.wsSynced = true;
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
    setConnStatus("reconnecting", "重连中...");
    state.reconnectTimer = setTimeout(() => connectSessionSocket(false), 2000);
  };

  ws.onerror = () => {
    ws.close();
  };
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && state.token && state.activeSessionId) {
    if (!state.ws || state.ws.readyState !== WebSocket.OPEN) {
      connectSessionSocket(false);
    }
  }
});

function updateSessionMeta(summary) {
  if (!summary) return;
  $("header-session-title").textContent = summary.title;
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

// --- Turn-Scoped Grouped Rendering (Deep Thinking + Tool Calls + Formatted Reply) ---

function ensureCurrentTurn() {
  if (state.currentTurn) return state.currentTurn;
  const box = $("chat-messages");
  const processWrap = document.createElement("div");
  processWrap.className = "turn-process-wrap hidden";
  box.appendChild(processWrap);

  state.currentTurn = {
    processWrap,
    // Deep Thinking drawer (collapsed by default)
    thoughtDetails: null,
    thoughtBadge: null,
    thoughtPre: null,
    thoughtRounds: [""],
    thoughtRoundIdx: 0,
    lastEventWasThought: false,
    // Tool Calls drawer (collapsed by default)
    toolsDetails: null,
    toolsBadge: null,
    toolsBody: null,
    toolCount: 0,
    toolItemsById: new Map(),
    lastToolName: "",
    // Assistant Markdown Reply
    assistantEl: null,
    assistantContentEl: null,
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
  details.className = "process-group thought-group"; // No `open` attr -> collapsed by default!
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
  details.className = "process-group tools-group"; // No `open` attr -> collapsed by default!
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

function ensureAssistantBubble(turn) {
  if (turn.assistantEl) return;
  const box = $("chat-messages");
  const div = document.createElement("div");
  div.className = "msg assistant";
  const md = document.createElement("div");
  md.className = "md-content";
  div.appendChild(md);
  box.appendChild(div);
  turn.assistantEl = div;
  turn.assistantContentEl = md;
}

function summarizeToolArg(name, args) {
  if (!args || typeof args !== "object") return "";
  if (args.path) return String(args.path);
  if (args.command) return String(args.command).slice(0, 42);
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

function renderEvent(ev) {
  const box = $("chat-messages");
  const d = ev.data || {};

  if (d.session) {
    updateSessionMeta(d.session);
  }

  if (ev.type === "user_message") {
    finalizeTurnDrawers(state.currentTurn);
    state.currentTurn = null;
    const div = document.createElement("div");
    div.className = "msg user";
    div.textContent = normalizeCleanText(d.text || "");
    box.appendChild(div);
    scrollChatBottom(true);
    return;
  }

  if (ev.type === "thought_delta") {
    if (state.wsSynced) setDynamicIslandState("thinking");
    const turn = ensureCurrentTurn();
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
    const turn = ensureCurrentTurn();
    turn.lastEventWasThought = false;
    turn.lastEventWasText = false;
    ensureToolsDrawer(turn);

    turn.toolCount += 1;
    const toolName = d.name || "tool";
    turn.lastToolName = toolName;
    const argPreview = summarizeToolArg(toolName, d.args);
    turn.toolsBadge.textContent = `已收纳 · ${turn.toolCount} 次 (${toolName})`;

    const item = document.createElement("details");
    item.className = "tool-subitem"; // Collapsed by default!
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
    const turn = ensureCurrentTurn();
    turn.lastEventWasThought = false;
    turn.lastEventWasText = false;
    ensureToolsDrawer(turn);

    const callId = d.id;
    let item = callId ? turn.toolItemsById.get(callId) : null;
    if (!item) {
      // Fallback if tool_result arrived without prior matching id
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
  } else if (ev.type === "text_delta") {
    if (state.wsSynced) setDynamicIslandState("answering");
    const turn = ensureCurrentTurn();
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
    finalizeTurnDrawers(state.currentTurn);
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

// Stable DOM-diffed renderPendingBox so existing buttons are NEVER destroyed mid-tap on iOS
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

  // 1. Batch bar when > 1 approval is queued
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

  // 2. Remove stale cards no longer in pending lists
  const activeIds = new Set([
    ...approvals.map((a) => `app-${a.request_id}`),
    ...interactions.map((i) => `int-${i.request_id}`),
  ]);
  box.querySelectorAll(".pending-item").forEach((el) => {
    if (!activeIds.has(el.dataset.domId)) {
      el.remove();
    }
  });

  // 3. Append only new approval cards
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

  // 4. Append only new interaction cards
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
  const prompt = input.value.trim();
  if (!prompt || !state.activeSessionId) return;

  state.sendingPrompt = true;
  $("send-btn").disabled = true;
  input.value = "";
  autoGrow(input);

  try {
    const res = await api(`/api/sessions/${state.activeSessionId}/message`, {
      method: "POST",
      body: JSON.stringify({ prompt, model: $("quick-model-select").value }),
    });
    if (res.session) updateSessionMeta(res.session);
  } catch (err) {
    input.value = prompt;
    autoGrow(input);
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
