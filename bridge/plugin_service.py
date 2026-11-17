from __future__ import annotations

import base64
import copy
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time
import zipfile
from typing import Any

import yaml


DSH_RUNTIME_NODE = Path(r"E:\新建文件夹\resources\runtime\bin\node.cmd")
DSH_RUNTIME_PNPM = Path(r"E:\新建文件夹\resources\runtime\pnpm\bin\pnpm.cjs")


def _slugify(name: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9._-]+", "-", (name or "").strip().lower()).strip("-.")
    return cleaned or f"plugin-{int(time.time())}"


def _atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp-{os.getpid()}-{threading.get_ident()}")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


class PluginService:
    """
    PC-side DSH plugin & skill manager configurable from mobile (no marketplace UI).

    Supports two compatible layers:
    1. Bridge PC plugins (`data/plugins/<id>/`): DSH bundles, Claude/AGY-compatible
       `plugin.json` + `SKILL.md` + runnable PC scripts (`tools/*.py|*.js|*.ps1`) + `mcp_config.json`.
    2. Native DSH Desktop Profile (`~/.dsh/profiles/desktop/`): reads/edits `package.json`
       (`dsh.profile.bundles`) and `cordis.patch.yml` (`id`, `disabled`, `config`), and can
       run `pnpm add <spec>` on the PC using the local DSH runtime.
    """

    def __init__(self, plugins_dir: Path | None = None, dsh_profile_dir: Path | None = None) -> None:
        self._lock = threading.RLock()
        default_root = Path(__file__).resolve().parent.parent / "data" / "plugins"
        self.plugins_dir = Path(plugins_dir or default_root).resolve()
        self.plugins_dir.mkdir(parents=True, exist_ok=True)
        self.state_path = self.plugins_dir / "state.json"

        default_dsh = Path.home() / ".dsh" / "profiles" / "desktop"
        self.dsh_profile_dir = Path(dsh_profile_dir) if dsh_profile_dir is not None else default_dsh
        self._state = self._load_state()

    def set_paths(self, *, plugins_dir: Path | None = None, dsh_profile_dir: Path | None = None) -> None:
        with self._lock:
            if plugins_dir is not None:
                self.plugins_dir = Path(plugins_dir).resolve()
                self.plugins_dir.mkdir(parents=True, exist_ok=True)
                self.state_path = self.plugins_dir / "state.json"
                self._state = self._load_state()
            if dsh_profile_dir is not None:
                self.dsh_profile_dir = Path(dsh_profile_dir)

    def _load_state(self) -> dict[str, dict[str, Any]]:
        if self.state_path.exists():
            try:
                raw = json.loads(self.state_path.read_text(encoding="utf-8"))
                if isinstance(raw, dict):
                    return raw
            except Exception:
                pass
        return {}

    def _save_state(self) -> None:
        with self._lock:
            _atomic_write_text(self.state_path, json.dumps(self._state, ensure_ascii=False, indent=2))

    # ------------------------------------------------------------------
    # Discovery of local Bridge PC plugins (`data/plugins/`)
    # ------------------------------------------------------------------
    def _inspect_plugin_dir(self, plugin_dir: Path) -> dict[str, Any]:
        plugin_id = plugin_dir.name
        state_entry = self._state.get(plugin_id, {})

        manifest: dict[str, Any] = {}
        for rel in ("plugin.json", ".dsh-plugin/plugin.json", ".claude-plugin/plugin.json", "package.json"):
            cand = plugin_dir / rel
            if cand.exists() and cand.is_file():
                try:
                    data = json.loads(cand.read_text(encoding="utf-8", errors="replace"))
                    if isinstance(data, dict):
                        manifest = data
                        break
                except Exception:
                    pass

        name = str(manifest.get("displayName") or manifest.get("name") or plugin_id)
        version = str(manifest.get("version") or "1.0.0")
        description = str(manifest.get("description") or "")
        author_raw = manifest.get("author")
        author = author_raw.get("name", "") if isinstance(author_raw, dict) else str(author_raw or "")

        # Skills discovery (`SKILL.md` and `skills/*/SKILL.md`)
        skills: list[dict[str, str]] = []
        root_skill = plugin_dir / "SKILL.md"
        if root_skill.exists():
            skills.append(
                {
                    "name": plugin_id,
                    "path": "SKILL.md",
                    "preview": root_skill.read_text(encoding="utf-8", errors="replace")[:400],
                }
            )
        skills_dir = plugin_dir / "skills"
        if skills_dir.exists() and skills_dir.is_dir():
            for sub in sorted(skills_dir.iterdir()):
                if sub.is_dir() and (sub / "SKILL.md").exists():
                    skills.append(
                        {
                            "name": sub.name,
                            "path": f"skills/{sub.name}/SKILL.md",
                            "preview": (sub / "SKILL.md").read_text(encoding="utf-8", errors="replace")[:400],
                        }
                    )

        # Executable PC tool scripts (`tools/`, `scripts/`, or `manifest["main"]`)
        tools: list[dict[str, str]] = []
        allowed_exts = {".py", ".js", ".mjs", ".cjs", ".ps1", ".cmd", ".bat"}
        for sub_name in ("tools", "scripts"):
            sub_dir = plugin_dir / sub_name
            if sub_dir.exists() and sub_dir.is_dir():
                for f in sorted(sub_dir.iterdir()):
                    if f.is_file() and f.suffix.lower() in allowed_exts:
                        tools.append({"name": f.stem, "rel_path": f"{sub_name}/{f.name}", "ext": f.suffix.lower()})
        main_entry = str(manifest.get("main") or "").strip()
        if main_entry and (plugin_dir / main_entry).is_file():
            rel_main = main_entry.replace("\\", "/")
            if not any(t["rel_path"] == rel_main for t in tools):
                tools.append(
                    {"name": Path(main_entry).stem, "rel_path": rel_main, "ext": Path(main_entry).suffix.lower()}
                )

        # MCP servers if defined
        mcp_servers: list[str] = []
        for mcp_name in ("mcp_config.json", "mcp.json"):
            mp = plugin_dir / mcp_name
            if mp.exists():
                try:
                    mdata = json.loads(mp.read_text(encoding="utf-8"))
                    if isinstance(mdata, dict) and isinstance(mdata.get("mcpServers"), dict):
                        mcp_servers.extend(list(mdata["mcpServers"].keys()))
                except Exception:
                    pass

        default_config = manifest.get("defaultConfig") if isinstance(manifest.get("defaultConfig"), dict) else {}
        config = copy.deepcopy(default_config)
        if isinstance(state_entry.get("config"), dict):
            config.update(state_entry["config"])

        default_enabled = not bool(manifest.get("disabled", False))
        enabled = bool(state_entry.get("enabled", default_enabled))
        env_map = dict(state_entry.get("env") or {})

        return {
            "id": plugin_id,
            "name": name,
            "version": version,
            "description": description,
            "author": author,
            "enabled": enabled,
            "source": str(state_entry.get("source") or "local"),
            "path": str(plugin_dir),
            "is_dsh_bundle": "dsh" in manifest or "dsh-plugin" in (manifest.get("keywords") or []),
            "skills": skills,
            "tools": tools,
            "mcp_servers": mcp_servers,
            "config": config,
            "env": env_map,
            "config_schema": manifest.get("configSchema") if isinstance(manifest.get("configSchema"), dict) else {},
            "installed_at": float(state_entry.get("installed_at") or plugin_dir.stat().st_mtime),
        }

    # ------------------------------------------------------------------
    # Native DSH Profile (`~/.dsh/profiles/desktop`)
    # ------------------------------------------------------------------
    def _inspect_dsh_profile(self) -> dict[str, Any]:
        pdir = self.dsh_profile_dir
        exists = pdir.exists() and (pdir / "package.json").exists()
        if not exists:
            return {
                "exists": False,
                "profile_dir": str(pdir),
                "bundles": [],
                "patches": [],
                "runtime_available": DSH_RUNTIME_PNPM.exists() or bool(shutil.which("pnpm")),
            }

        bundles: list[dict[str, Any]] = []
        try:
            pkg = json.loads((pdir / "package.json").read_text(encoding="utf-8", errors="replace"))
        except Exception:
            pkg = {}
        active_bundles = list(((pkg.get("dsh") or {}).get("profile") or {}).get("bundles") or [])
        deps = dict(pkg.get("dependencies") or {})
        seen = set()
        for bname in [*active_bundles, *deps.keys()]:
            if bname in seen:
                continue
            seen.add(bname)
            pkg_meta: dict[str, Any] = {}
            mod_pkg = pdir / "node_modules" / Path(*bname.split("/")) / "package.json"
            if mod_pkg.exists():
                try:
                    pkg_meta = json.loads(mod_pkg.read_text(encoding="utf-8", errors="replace"))
                except Exception:
                    pass
            bundles.append(
                {
                    "name": bname,
                    "enabled": bname in active_bundles,
                    "version": str(pkg_meta.get("version") or deps.get(bname) or "builtin"),
                    "description": str(pkg_meta.get("description") or ""),
                    "installed_in_deps": bname in deps,
                }
            )

        patches: list[dict[str, Any]] = []
        patch_file = pdir / "cordis.patch.yml"
        if patch_file.exists():
            try:
                loaded = yaml.safe_load(patch_file.read_text(encoding="utf-8", errors="replace")) or []
                if isinstance(loaded, list):
                    for idx, item in enumerate(loaded):
                        if not isinstance(item, dict):
                            continue
                        if "insert" in item and isinstance(item["insert"], list):
                            for sub in item["insert"]:
                                if isinstance(sub, dict):
                                    patches.append(
                                        {
                                            "id": str(sub.get("id") or f"insert-{idx}"),
                                            "name": str(sub.get("name") or sub.get("id") or ""),
                                            "enabled": not bool(sub.get("disabled", False)),
                                            "config": sub.get("config") if isinstance(sub.get("config"), dict) else {},
                                            "kind": "insert",
                                        }
                                    )
                        else:
                            eid = str(item.get("id") or f"entry-{idx}")
                            patches.append(
                                {
                                    "id": eid,
                                    "name": str(item.get("name") or eid),
                                    "enabled": not bool(item.get("disabled", False)),
                                    "config": item.get("config") if isinstance(item.get("config"), dict) else {},
                                    "kind": "override",
                                }
                            )
            except Exception:
                pass

        return {
            "exists": True,
            "profile_dir": str(pdir),
            "bundles": bundles,
            "patches": patches,
            "runtime_available": DSH_RUNTIME_PNPM.exists() or bool(shutil.which("pnpm")),
        }

    def list_all(self) -> dict[str, Any]:
        with self._lock:
            plugins: list[dict[str, Any]] = []
            for item in sorted(self.plugins_dir.iterdir()):
                if item.is_dir() and not item.name.startswith("."):
                    plugins.append(self._inspect_plugin_dir(item))
            dsh_profile = self._inspect_dsh_profile()
            enabled_plugins = sum(1 for p in plugins if p["enabled"])
            enabled_bundles = sum(1 for b in dsh_profile.get("bundles", []) if b.get("enabled"))
            return {
                "plugins": plugins,
                "dsh_profile": dsh_profile,
                "summary": {
                    "total": len(plugins),
                    "enabled": enabled_plugins,
                    "dsh_profile_exists": dsh_profile["exists"],
                    "dsh_bundles_enabled": enabled_bundles,
                    "dsh_bundles_total": len(dsh_profile.get("bundles", [])),
                },
            }

    def summary(self) -> dict[str, Any]:
        return self.list_all()["summary"]

    # ------------------------------------------------------------------
    # Install / Configure / Toggle / Uninstall PC Plugins
    # ------------------------------------------------------------------
    def _register_state(
        self,
        plugin_id: str,
        *,
        source: str,
        enabled: bool = True,
        config: dict[str, Any] | None = None,
        env: dict[str, str] | None = None,
    ) -> None:
        with self._lock:
            prev = self._state.get(plugin_id, {})
            merged_cfg = dict(prev.get("config") or {})
            if config:
                merged_cfg.update(config)
            merged_env = dict(prev.get("env") or {})
            if env:
                merged_env.update(env)
            self._state[plugin_id] = {
                "enabled": enabled,
                "source": source,
                "config": merged_cfg,
                "env": merged_env,
                "installed_at": time.time(),
            }
            self._save_state()

    def install_from_local_path(self, source_path: str, *, name: str = "", config: dict[str, Any] | None = None) -> dict[str, Any]:
        src = Path(source_path).expanduser().resolve()
        if not src.exists():
            raise FileNotFoundError(f"路径不存在: {src}")
        plugin_id = _slugify(name or src.stem)
        dest = self.plugins_dir / plugin_id
        with self._lock:
            if dest.exists():
                shutil.rmtree(dest)
            if src.is_dir():
                shutil.copytree(src, dest, ignore=shutil.ignore_patterns(".git", "__pycache__", "node_modules"))
            else:
                dest.mkdir(parents=True, exist_ok=True)
                self._place_single_file(dest, plugin_id, src.name, src.read_bytes())
            self._register_state(plugin_id, source=f"local:{src}", enabled=True, config=config)
            return self._inspect_plugin_dir(dest)

    def _place_single_file(self, dest: Path, plugin_id: str, filename: str, data: bytes) -> None:
        fname = Path(filename).name
        ext = Path(fname).suffix.lower()
        if ext == ".zip":
            tmp_zip = dest / "__upload.zip"
            tmp_zip.write_bytes(data)
            try:
                with zipfile.ZipFile(tmp_zip, "r") as zf:
                    for member in zf.infolist():
                        # Prevent zip slip
                        member_path = Path(member.filename)
                        if member_path.is_absolute() or ".." in member_path.parts:
                            raise ValueError(f"不安全的压缩包路径: {member.filename}")
                    zf.extractall(dest)
            finally:
                tmp_zip.unlink(missing_ok=True)
            # Flatten if archive contained a single top-level directory
            children = [p for p in dest.iterdir()]
            if len(children) == 1 and children[0].is_dir():
                inner = children[0]
                for sub in inner.iterdir():
                    shutil.move(str(sub), str(dest / sub.name))
                inner.rmdir()
        elif ext in (".py", ".js", ".mjs", ".ps1"):
            tools_dir = dest / "tools"
            tools_dir.mkdir(parents=True, exist_ok=True)
            (tools_dir / fname).write_bytes(data)
            if not (dest / "plugin.json").exists():
                (dest / "plugin.json").write_text(
                    json.dumps(
                        {"name": plugin_id, "version": "1.0.0", "description": f"Uploaded PC script plugin ({fname})"},
                        ensure_ascii=False,
                        indent=2,
                    ),
                    encoding="utf-8",
                )
        elif ext == ".md":
            (dest / "SKILL.md").write_bytes(data)
            if not (dest / "plugin.json").exists():
                (dest / "plugin.json").write_text(
                    json.dumps(
                        {"name": plugin_id, "version": "1.0.0", "description": f"Uploaded SKILL plugin ({fname})"},
                        ensure_ascii=False,
                        indent=2,
                    ),
                    encoding="utf-8",
                )
        elif ext == ".json":
            target_name = "mcp_config.json" if b"mcpServers" in data else "plugin.json"
            (dest / target_name).write_bytes(data)
        else:
            (dest / fname).write_bytes(data)

    def install_from_upload(
        self,
        *,
        filename: str,
        content_base64: str,
        name: str = "",
        description: str = "",
        config: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        raw = base64.b64decode(content_base64)
        base_stem = Path(filename).stem
        plugin_id = _slugify(name or base_stem)
        dest = self.plugins_dir / plugin_id
        with self._lock:
            if dest.exists():
                shutil.rmtree(dest)
            dest.mkdir(parents=True, exist_ok=True)
            self._place_single_file(dest, plugin_id, filename, raw)
            if description and not (dest / "plugin.json").exists():
                (dest / "plugin.json").write_text(
                    json.dumps({"name": name or plugin_id, "version": "1.0.0", "description": description}, indent=2),
                    encoding="utf-8",
                )
            self._register_state(plugin_id, source=f"mobile-upload:{filename}", enabled=True, config=config)
            return self._inspect_plugin_dir(dest)

    def install_from_git(self, git_url: str, *, name: str = "", branch: str = "", config: dict[str, Any] | None = None) -> dict[str, Any]:
        url = git_url.strip()
        if not (url.startswith("https://") or url.startswith("http://") or url.startswith("git@")):
            raise ValueError("仅支持 https://, http:// 或 git@ 仓库地址")
        repo_stem = Path(url.rstrip("/").split("/")[-1]).stem
        plugin_id = _slugify(name or repo_stem)
        dest = self.plugins_dir / plugin_id
        cmd = ["git", "clone", "--depth", "1"]
        if branch.strip():
            cmd.extend(["-b", branch.strip()])
        cmd.extend([url, str(dest)])

        with self._lock:
            if dest.exists():
                shutil.rmtree(dest)
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
            if proc.returncode != 0:
                shutil.rmtree(dest, ignore_errors=True)
                raise RuntimeError(f"git clone 失败: {(proc.stderr or proc.stdout).strip()}")
            self._register_state(plugin_id, source=f"git:{url}", enabled=True, config=config)
            return self._inspect_plugin_dir(dest)

    def install_inline(
        self,
        *,
        name: str,
        description: str = "",
        skill_markdown: str = "",
        script_code: str = "",
        script_language: str = "python",
        config: dict[str, Any] | None = None,
        env: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        plugin_id = _slugify(name)
        dest = self.plugins_dir / plugin_id
        with self._lock:
            dest.mkdir(parents=True, exist_ok=True)
            manifest = {
                "name": name.strip() or plugin_id,
                "version": "1.0.0",
                "description": description.strip() or "Configured from iPhone, executed on PC",
            }
            (dest / "plugin.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
            if skill_markdown.strip():
                (dest / "SKILL.md").write_text(skill_markdown, encoding="utf-8")
            if script_code.strip():
                ext = {"python": ".py", "javascript": ".js", "powershell": ".ps1"}.get(
                    script_language.lower(), ".py"
                )
                tdir = dest / "tools"
                tdir.mkdir(parents=True, exist_ok=True)
                (tdir / f"run{ext}").write_text(script_code, encoding="utf-8")
            self._register_state(plugin_id, source="mobile-inline", enabled=True, config=config, env=env)
            return self._inspect_plugin_dir(dest)

    def toggle_plugin(self, plugin_id: str, enabled: bool) -> dict[str, Any]:
        dest = self.plugins_dir / plugin_id
        if not dest.exists():
            raise FileNotFoundError(f"插件不存在: {plugin_id}")
        with self._lock:
            entry = self._state.setdefault(plugin_id, {})
            entry["enabled"] = bool(enabled)
            self._save_state()
            return self._inspect_plugin_dir(dest)

    def update_plugin_config(
        self,
        plugin_id: str,
        *,
        config: dict[str, Any] | None = None,
        env: dict[str, str] | None = None,
        enabled: bool | None = None,
    ) -> dict[str, Any]:
        dest = self.plugins_dir / plugin_id
        if not dest.exists():
            raise FileNotFoundError(f"插件不存在: {plugin_id}")
        with self._lock:
            entry = self._state.setdefault(plugin_id, {})
            if config is not None:
                entry["config"] = dict(config)
            if env is not None:
                entry["env"] = {str(k): str(v) for k, v in env.items()}
            if enabled is not None:
                entry["enabled"] = bool(enabled)
            self._save_state()
            return self._inspect_plugin_dir(dest)

    def uninstall_plugin(self, plugin_id: str) -> None:
        dest = (self.plugins_dir / plugin_id).resolve()
        if dest.parent != self.plugins_dir or not dest.exists():
            raise FileNotFoundError(f"插件不存在: {plugin_id}")
        with self._lock:
            shutil.rmtree(dest)
            self._state.pop(plugin_id, None)
            self._save_state()

    def run_plugin_tool(
        self,
        plugin_id: str,
        *,
        tool_name: str = "",
        args: list[str] | None = None,
        stdin_text: str = "",
        workspace_cwd: str = "",
        timeout_sec: int = 20,
    ) -> dict[str, Any]:
        dest = self.plugins_dir / plugin_id
        if not dest.exists():
            raise FileNotFoundError(f"插件不存在: {plugin_id}")
        info = self._inspect_plugin_dir(dest)
        if not info["enabled"]:
            raise RuntimeError(f"插件 {plugin_id} 当前已禁用，请先启用。")
        tools = info["tools"]
        if not tools:
            raise RuntimeError(f"插件 {plugin_id} 未声明可执行 PC 脚本（tools/ 或 scripts/）")

        selected = None
        if tool_name:
            for t in tools:
                if t["name"] == tool_name or t["rel_path"] == tool_name:
                    selected = t
                    break
        if selected is None:
            selected = tools[0]

        script_path = (dest / selected["rel_path"]).resolve()
        ext = script_path.suffix.lower()
        if ext == ".py":
            cmd = [sys.executable, str(script_path), *(args or [])]
        elif ext in (".js", ".mjs", ".cjs"):
            node_bin = str(DSH_RUNTIME_NODE) if DSH_RUNTIME_NODE.exists() else (shutil.which("node") or "node")
            cmd = [node_bin, str(script_path), *(args or [])]
        elif ext == ".ps1":
            cmd = [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(script_path),
                *(args or []),
            ]
        else:
            cmd = [str(script_path), *(args or [])]

        env = os.environ.copy()
        env["DSH_PLUGIN_ID"] = plugin_id
        env["DSH_PLUGIN_DIR"] = str(dest)
        env["DSH_PLUGIN_CONFIG"] = json.dumps(info["config"], ensure_ascii=False)
        env["PYTHONIOENCODING"] = "utf-8"
        for k, v in (info.get("env") or {}).items():
            env[str(k)] = str(v)

        cwd = workspace_cwd if (workspace_cwd and Path(workspace_cwd).is_dir()) else str(dest)
        started = time.perf_counter()
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            env=env,
            input=stdin_text,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=max(2, min(int(timeout_sec), 60)),
        )
        return {
            "ok": proc.returncode == 0,
            "plugin_id": plugin_id,
            "tool": selected["name"],
            "exit_code": proc.returncode,
            "stdout": (proc.stdout or "")[:65536],
            "stderr": (proc.stderr or "")[:32768],
            "duration_ms": round((time.perf_counter() - started) * 1000, 1),
            "executed_on": "PC",
        }

    # ------------------------------------------------------------------
    # Native DSH Profile (`~/.dsh/profiles/desktop`) Configuration & Install
    # ------------------------------------------------------------------
    def _require_dsh_profile(self) -> Path:
        if not self.dsh_profile_dir.exists() or not (self.dsh_profile_dir / "package.json").exists():
            raise FileNotFoundError(f"未检测到 DSH Desktop Profile: {self.dsh_profile_dir}")
        return self.dsh_profile_dir

    def toggle_dsh_bundle(self, bundle_name: str, enabled: bool) -> dict[str, Any]:
        with self._lock:
            pdir = self._require_dsh_profile()
            pkg_path = pdir / "package.json"
            pkg = json.loads(pkg_path.read_text(encoding="utf-8"))
            dsh_obj = pkg.setdefault("dsh", {}).setdefault("profile", {})
            bundles: list[str] = list(dsh_obj.get("bundles") or [])
            if enabled and bundle_name not in bundles:
                bundles.append(bundle_name)
            elif not enabled and bundle_name in bundles:
                bundles = [b for b in bundles if b != bundle_name]
            dsh_obj["bundles"] = bundles
            shutil.copy2(pkg_path, pkg_path.with_suffix(".json.bak"))
            _atomic_write_text(pkg_path, json.dumps(pkg, ensure_ascii=False, indent=2) + "\n")
            return self._inspect_dsh_profile()

    def update_dsh_patch_entry(
        self, entry_id: str, *, enabled: bool | None = None, config: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        with self._lock:
            pdir = self._require_dsh_profile()
            patch_path = pdir / "cordis.patch.yml"
            rows = []
            if patch_path.exists():
                rows = yaml.safe_load(patch_path.read_text(encoding="utf-8")) or []
            if not isinstance(rows, list):
                rows = []

            found = False
            for row in rows:
                if not isinstance(row, dict):
                    continue
                if row.get("id") == entry_id:
                    found = True
                    if enabled is not None:
                        if enabled:
                            row.pop("disabled", None)
                        else:
                            row["disabled"] = True
                    if config is not None:
                        row["config"] = config
                    break
                if isinstance(row.get("insert"), list):
                    for sub in row["insert"]:
                        if isinstance(sub, dict) and sub.get("id") == entry_id:
                            found = True
                            if enabled is not None:
                                if enabled:
                                    sub.pop("disabled", None)
                                else:
                                    sub["disabled"] = True
                            if config is not None:
                                sub["config"] = config
                            break
                if found:
                    break

            if not found:
                new_row: dict[str, Any] = {"id": entry_id}
                if enabled is False:
                    new_row["disabled"] = True
                if config is not None:
                    new_row["config"] = config
                rows.append(new_row)

            if patch_path.exists():
                shutil.copy2(patch_path, patch_path.with_suffix(".yml.bak"))
            _atomic_write_text(patch_path, yaml.safe_dump(rows, allow_unicode=True, sort_keys=False))
            return self._inspect_dsh_profile()

    def install_dsh_package(self, spec: str) -> dict[str, Any]:
        """Install a specific DSH npm/tarball/git spec into the local DSH profile via PC pnpm."""
        cleaned = spec.strip()
        if not cleaned or any(c in cleaned for c in (";", "&", "|", "`", "$", "\n", "\r")):
            raise ValueError("非法的包名或路径格式")
        pdir = self._require_dsh_profile()

        if DSH_RUNTIME_NODE.exists() and DSH_RUNTIME_PNPM.exists():
            cmd = [str(DSH_RUNTIME_NODE), str(DSH_RUNTIME_PNPM), "add", cleaned]
        else:
            pnpm_bin = shutil.which("pnpm")
            if not pnpm_bin:
                raise RuntimeError("未在 PC 找到 DSH pnpm 运行时或全局 pnpm")
            cmd = [pnpm_bin, "add", cleaned]

        proc = subprocess.run(
            cmd,
            cwd=str(pdir),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"DSH 插件安装失败:\n{(proc.stderr or proc.stdout).strip()[:1200]}")

        # Auto-enable package name in dsh.profile.bundles if discoverable
        pkg_name = cleaned
        if not cleaned.startswith(".") and not cleaned.startswith("git"):
            pkg_name = cleaned.split("@", 1)[0] if not cleaned.startswith("@") else "@" + cleaned[1:].split("@", 1)[0]
        try:
            self.toggle_dsh_bundle(pkg_name, True)
        except Exception:
            pass
        return {
            "ok": True,
            "spec": cleaned,
            "stdout": (proc.stdout or "")[-2000:],
            "dsh_profile": self._inspect_dsh_profile(),
        }

    # ------------------------------------------------------------------
    # Prompt Injection Helper for AI Session
    # ------------------------------------------------------------------
    def get_agent_prompt_appendix(self) -> str:
        with self._lock:
            enabled = [self._inspect_plugin_dir(p) for p in sorted(self.plugins_dir.iterdir()) if p.is_dir()]
        enabled = [p for p in enabled if p["enabled"]]
        if not enabled:
            return ""
        chunks = [
            "\n\n## Active PC DSH Plugins (Configured on Mobile, Executed on PC)",
            "Use `list_plugins` or `run_plugin` when a user task matches one of these active PC plugins:",
        ]
        for p in enabled[:12]:
            tool_names = ", ".join(t["name"] for t in p["tools"]) or "instruction-only"
            chunks.append(f"- **{p['id']}** ({p['name']}): {p['description'] or 'No description'} | tools: {tool_names}")
            for sk in p["skills"][:2]:
                snippet = " ".join(sk["preview"].splitlines())[:220]
                chunks.append(f"  skill `{sk['name']}`: {snippet}")
        return "\n".join(chunks)
