"""Filesystem and Git operations:
1. User Full-PC File Manager (C:, D:, E: drives, full metadata, move, copy, rename, delete, upload, download)
2. AI Sandbox Isolation (workspace_only | workspace_read_all | full_access)
"""

from __future__ import annotations

import asyncio
import ctypes
import mimetypes
import os
import shutil
import stat as stat_mod
import string
import subprocess
from pathlib import Path
from typing import Any

SKIP_DIRS = {
    ".git",
    ".venv",
    "venv",
    "node_modules",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    "dist",
    "build",
}


class WorkspaceSecurityError(PermissionError):
    """Raised when a path attempts to escape the configured workspace root."""


class FileConflictError(RuntimeError):
    """Raised when a file changed on disk since it was loaded in the mobile editor."""


def _is_within_any_workspace(target: Path, allowed_workspaces: list[str]) -> bool:
    try:
        resolved = target.resolve()
    except OSError:
        resolved = target
    for ws in allowed_workspaces:
        try:
            ws_root = Path(ws).resolve()
            if resolved == ws_root or resolved.is_relative_to(ws_root):
                return True
        except OSError:
            continue
    return False


def resolve_workspace_path(workspace_root: Path, rel_path: str = "") -> Path:
    """Resolve `rel_path` strictly inside `workspace_root`."""
    root = workspace_root.resolve()
    clean = (rel_path or "").replace("\\", "/").strip()
    if "\x00" in clean:
        raise WorkspaceSecurityError("Null byte in path")
    if clean.startswith("/") or (len(clean) >= 2 and clean[1] == ":"):
        raise WorkspaceSecurityError("Absolute paths are not allowed")

    target = (root / clean).resolve() if clean else root
    if target != root and not target.is_relative_to(root):
        raise WorkspaceSecurityError("Path escapes workspace boundary")
    return target


def resolve_ai_path(
    workspace_root: Path,
    raw_path: str = "",
    *,
    allowed_workspaces: list[str] | None = None,
    ai_access_mode: str = "workspace_only",
    is_write: bool = False,
) -> Path:
    """Resolve a path for an AI tool call while enforcing the user's AI isolation policy."""
    root = workspace_root.resolve()
    clean = (raw_path or "").strip()
    if "\x00" in clean:
        raise WorkspaceSecurityError("Null byte in path")

    if not clean:
        return root

    p = Path(clean)
    if p.is_absolute() or (len(clean) >= 2 and clean[1] == ":"):
        target = p.resolve()
    else:
        target = (root / clean.replace("\\", "/")).resolve()

    ws_list = list(allowed_workspaces or [])
    if str(root) not in ws_list:
        ws_list.append(str(root))

    in_ws = _is_within_any_workspace(target, ws_list)
    if in_ws:
        return target

    if ai_access_mode == "full_access":
        return target
    if ai_access_mode == "workspace_read_all" and not is_write:
        return target

    raise WorkspaceSecurityError(
        f"Path escapes workspace boundary (当前 AI 处于隔离模式 '{ai_access_mode}'，无权访问工作区外路径: {target})"
    )


def to_rel_posix(workspace_root: Path, path: Path) -> str:
    root = workspace_root.resolve()
    target = path.resolve()
    if target == root:
        return ""
    try:
        return target.relative_to(root).as_posix()
    except ValueError:
        return str(target)


# ============================================================================
# Full PC File System Manager (User-Facing, Isolated from AI Restrictions)
# ============================================================================


def _get_volume_label(drive_root: str) -> str:
    if os.name != "nt":
        return "Disk"
    try:
        buf = ctypes.create_unicode_buffer(261)
        fs_buf = ctypes.create_unicode_buffer(261)
        ctypes.windll.kernel32.GetVolumeInformationW(
            ctypes.c_wchar_p(drive_root),
            buf,
            260,
            None,
            None,
            None,
            fs_buf,
            260,
        )
        return buf.value.strip() or "本地磁盘"
    except Exception:
        return "本地磁盘"


def list_pc_drives(
    allowed_workspaces: list[str],
    active_workspace: str,
    ai_access_mode: str = "workspace_only",
) -> dict[str, Any]:
    """List all mounted Windows drives (C:, D:, E:, etc.) and quick-access locations."""
    drives: list[dict[str, Any]] = []
    if os.name == "nt":
        for letter in string.ascii_uppercase:
            root = f"{letter}:\\"
            if os.path.exists(root):
                try:
                    usage = shutil.disk_usage(root)
                    label = _get_volume_label(root)
                    drives.append(
                        {
                            "letter": f"{letter}:",
                            "name": f"{letter}: 盘 ({label})",
                            "label": label,
                            "path": root,
                            "total_bytes": usage.total,
                            "used_bytes": usage.used,
                            "free_bytes": usage.free,
                        }
                    )
                except OSError:
                    continue
    else:
        usage = shutil.disk_usage("/")
        drives.append(
            {
                "letter": "/",
                "name": "根目录 (/)",
                "label": "Root",
                "path": "/",
                "total_bytes": usage.total,
                "used_bytes": usage.used,
                "free_bytes": usage.free,
            }
        )

    home = Path.home()
    shortcuts: list[dict[str, str]] = []
    if active_workspace and Path(active_workspace).exists():
        shortcuts.append({"name": "当前 AI 工作区", "path": str(Path(active_workspace).resolve()), "icon": "sparkles"})
    for label, sub, icon in [
        ("桌面", home / "Desktop", "desktopcomputer"),
        ("下载", home / "Downloads", "arrow.down.circle"),
        ("文档", home / "Documents", "doc.text"),
        ("用户主目录", home, "person.crop.circle"),
    ]:
        if sub.exists():
            shortcuts.append({"name": label, "path": str(sub.resolve()), "icon": icon})

    return {
        "drives": drives,
        "shortcuts": shortcuts,
        "workspaces": allowed_workspaces,
        "active_workspace": active_workspace,
        "ai_access_mode": ai_access_mode,
    }


def _is_hidden_entry(p: Path, st: os.stat_result) -> bool:
    if p.name.startswith("."):
        return True
    file_attrs = getattr(st, "st_file_attributes", 0)
    if file_attrs and (file_attrs & stat_mod.FILE_ATTRIBUTE_HIDDEN):
        return True
    return False


def get_pc_entry_metadata(
    target: Path,
    allowed_workspaces: list[str],
    ai_access_mode: str = "workspace_only",
) -> dict[str, Any]:
    st = target.stat()
    is_dir = target.is_dir()
    ext = "" if is_dir else target.suffix.lower()
    mime, _ = mimetypes.guess_type(target.name)
    in_ws = _is_within_any_workspace(target, allowed_workspaces)
    ai_can_read = in_ws or ai_access_mode in ("workspace_read_all", "full_access")
    ai_can_write = in_ws or ai_access_mode == "full_access"
    is_readonly = not os.access(target, os.W_OK)

    return {
        "name": target.name or str(target),
        "path": str(target.resolve()),
        "parent_path": str(target.resolve().parent) if target.resolve().parent != target.resolve() else "",
        "is_dir": is_dir,
        "size": 0 if is_dir else st.st_size,
        "mtime": st.st_mtime,
        "ctime": st.st_ctime,
        "atime": st.st_atime,
        "ext": ext,
        "mime_type": "inode/directory" if is_dir else (mime or "application/octet-stream"),
        "is_readonly": is_readonly,
        "is_hidden": _is_hidden_entry(target, st),
        "in_ai_workspace": in_ws,
        "ai_can_read": ai_can_read,
        "ai_can_write": ai_can_write,
    }


def list_pc_directory(
    path_str: str,
    allowed_workspaces: list[str],
    ai_access_mode: str = "workspace_only",
    *,
    show_hidden: bool = False,
) -> dict[str, Any]:
    """List any directory on the PC (C:\\, D:\\, E:\\, etc.) with full metadata."""
    clean = (path_str or "").strip()
    if not clean:
        target = Path(allowed_workspaces[0]).resolve() if allowed_workspaces else Path("C:\\" if os.name == "nt" else "/")
    else:
        if len(clean) == 2 and clean[1] == ":":
            clean = clean + "\\"
        target = Path(clean).resolve()

    if not target.exists():
        raise FileNotFoundError(f"路径不存在: {clean}")
    if not target.is_dir():
        raise NotADirectoryError(f"不是目录: {clean}")

    entries: list[dict[str, Any]] = []
    try:
        children = list(target.iterdir())
    except PermissionError as exc:
        raise PermissionError(f"系统拒绝访问该目录: {target}") from exc

    for item in children:
        try:
            meta = get_pc_entry_metadata(item, allowed_workspaces, ai_access_mode)
            if not show_hidden and meta["is_hidden"]:
                continue
            entries.append(meta)
        except OSError:
            continue

    entries.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))
    parent_path = str(target.parent) if target.parent != target else ""
    in_ws = _is_within_any_workspace(target, allowed_workspaces)

    return {
        "path": str(target),
        "name": target.name or str(target),
        "parent_path": parent_path,
        "drive": target.drive or "/",
        "in_ai_workspace": in_ws,
        "ai_can_write": in_ws or ai_access_mode == "full_access",
        "entries": entries,
    }


def stat_pc_entry(
    path_str: str,
    allowed_workspaces: list[str],
    ai_access_mode: str = "workspace_only",
) -> dict[str, Any]:
    """Return detailed properties for any file or folder on the PC."""
    clean = path_str.strip()
    if len(clean) == 2 and clean[1] == ":":
        clean += "\\"
    target = Path(clean).resolve()
    if not target.exists():
        raise FileNotFoundError(f"文件或目录不存在: {path_str}")

    meta = get_pc_entry_metadata(target, allowed_workspaces, ai_access_mode)
    if meta["is_dir"]:
        try:
            children = list(target.iterdir())
            meta["item_count"] = len(children)
            meta["dir_count"] = sum(1 for c in children if c.is_dir())
            meta["file_count"] = sum(1 for c in children if not c.is_dir())
        except OSError:
            meta["item_count"] = 0
    return meta


def read_pc_file(path_str: str, *, max_bytes: int = 2_000_000) -> dict[str, Any]:
    """Read any text file on the PC for the mobile user."""
    target = Path(path_str.strip()).resolve()
    if not target.exists():
        raise FileNotFoundError(f"文件不存在: {path_str}")
    if target.is_dir():
        raise IsADirectoryError(f"该路径是目录: {path_str}")

    st = target.stat()
    if st.st_size > max_bytes:
        return {
            "path": str(target),
            "name": target.name,
            "ext": target.suffix.lower(),
            "size": st.st_size,
            "mtime": st.st_mtime,
            "is_binary": False,
            "too_large": True,
            "content": "",
        }

    raw = target.read_bytes()
    if b"\x00" in raw[:8192]:
        return {
            "path": str(target),
            "name": target.name,
            "ext": target.suffix.lower(),
            "size": st.st_size,
            "mtime": st.st_mtime,
            "is_binary": True,
            "too_large": False,
            "content": "",
        }

    for enc in ("utf-8", "utf-8-sig", "gbk", "latin-1"):
        try:
            text = raw.decode(enc)
            return {
                "path": str(target),
                "name": target.name,
                "ext": target.suffix.lower(),
                "size": st.st_size,
                "mtime": st.st_mtime,
                "encoding": enc,
                "is_binary": False,
                "too_large": False,
                "content": text,
            }
        except UnicodeDecodeError:
            continue

    return {
        "path": str(target),
        "name": target.name,
        "ext": target.suffix.lower(),
        "size": st.st_size,
        "mtime": st.st_mtime,
        "is_binary": True,
        "too_large": False,
        "content": "",
    }


def write_pc_file(path_str: str, content: str) -> dict[str, Any]:
    """Write text content to any file on the PC on behalf of the authenticated mobile user."""
    target = Path(path_str.strip()).resolve()
    if target.exists() and target.is_dir():
        raise IsADirectoryError(f"该路径是目录: {path_str}")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    st = target.stat()
    return {
        "path": str(target),
        "name": target.name,
        "size": st.st_size,
        "mtime": st.st_mtime,
    }


def create_pc_entry(path_str: str, *, is_dir: bool = False, content: str = "") -> dict[str, Any]:
    target = Path(path_str.strip()).resolve()
    if target.exists():
        raise FileExistsError(f"已存在同名文件或目录: {target.name}")
    if is_dir:
        target.mkdir(parents=True, exist_ok=True)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    st = target.stat()
    return {
        "path": str(target),
        "name": target.name,
        "is_dir": is_dir,
        "size": 0 if is_dir else st.st_size,
        "mtime": st.st_mtime,
    }


def rename_or_move_pc_entry(src_path: str, dst_path: str, *, overwrite: bool = False) -> dict[str, Any]:
    src = Path(src_path.strip()).resolve()
    dst = Path(dst_path.strip()).resolve()
    if not src.exists():
        raise FileNotFoundError(f"源路径不存在: {src}")
    if src.parent == src:
        raise PermissionError("不能移动磁盘根目录")
    if dst.exists() and dst.is_dir() and dst != src.parent:
        # If destination is an existing directory and doesn't include the filename yet
        if dst.name != src.name or dst.parent != src.parent:
            pass
    if dst.exists() and not overwrite:
        raise FileExistsError(f"目标已存在: {dst}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(src), str(dst))
    return {"path": str(dst), "name": dst.name}


def copy_pc_entry(src_path: str, dst_path: str, *, overwrite: bool = False) -> dict[str, Any]:
    src = Path(src_path.strip()).resolve()
    dst = Path(dst_path.strip()).resolve()
    if not src.exists():
        raise FileNotFoundError(f"源路径不存在: {src}")

    if src == dst or (dst.exists() and not overwrite):
        # Automatically generate a non-colliding copy name if pasted in same dir
        stem = dst.stem
        suffix = dst.suffix
        parent = dst.parent
        counter = 1
        while dst.exists():
            dst = parent / f"{stem} - 副本{'' if counter == 1 else f' ({counter})'}{suffix}"
            counter += 1

    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_dir():
        shutil.copytree(src, dst, dirs_exist_ok=overwrite)
    else:
        shutil.copy2(src, dst)
    return {"path": str(dst), "name": dst.name}


def delete_pc_entry(path_str: str) -> dict[str, Any]:
    target = Path(path_str.strip()).resolve()
    if not target.exists():
        raise FileNotFoundError(f"路径不存在: {target}")
    if target.parent == target:
        raise PermissionError("禁止删除磁盘根目录")
    if target.is_dir():
        shutil.rmtree(target)
    else:
        target.unlink()
    return {"deleted": str(target)}


# ============================================================================
# Workspace-Scoped Operations (Used by Legacy APIs & AI Sandbox)
# ============================================================================


def list_directory(
    workspace_root: Path,
    rel_path: str = "",
    *,
    include_ignored: bool = False,
    allowed_workspaces: list[str] | None = None,
    ai_access_mode: str = "workspace_only",
) -> dict[str, Any]:
    """List immediate children of a directory."""
    target = resolve_ai_path(
        workspace_root,
        rel_path,
        allowed_workspaces=allowed_workspaces,
        ai_access_mode=ai_access_mode,
        is_write=False,
    )
    if not target.exists():
        raise FileNotFoundError(f"Directory not found: {rel_path}")
    if not target.is_dir():
        raise NotADirectoryError(f"Not a directory: {rel_path}")

    entries: list[dict[str, Any]] = []
    for item in target.iterdir():
        if not include_ignored and item.name in SKIP_DIRS:
            continue
        try:
            stat = item.stat()
        except OSError:
            continue
        is_dir = item.is_dir()
        entries.append(
            {
                "name": item.name,
                "path": to_rel_posix(workspace_root, item),
                "abs_path": str(item.resolve()),
                "is_dir": is_dir,
                "size": 0 if is_dir else stat.st_size,
                "mtime": stat.st_mtime,
                "ctime": stat.st_ctime,
                "ext": "" if is_dir else item.suffix.lower(),
            }
        )

    entries.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))
    return {
        "workspace": str(workspace_root.resolve()),
        "path": to_rel_posix(workspace_root, target),
        "abs_path": str(target.resolve()),
        "entries": entries,
    }


def read_file_content(
    workspace_root: Path,
    rel_path: str,
    *,
    max_bytes: int = 1_500_000,
    allowed_workspaces: list[str] | None = None,
    ai_access_mode: str = "workspace_only",
) -> dict[str, Any]:
    """Read a text file inside `workspace_root` (or allowed AI scope)."""
    target = resolve_ai_path(
        workspace_root,
        rel_path,
        allowed_workspaces=allowed_workspaces,
        ai_access_mode=ai_access_mode,
        is_write=False,
    )
    if not target.exists():
        raise FileNotFoundError(f"File not found: {rel_path}")
    if target.is_dir():
        raise IsADirectoryError(f"Path is a directory: {rel_path}")

    stat = target.stat()
    rel = to_rel_posix(workspace_root, target)
    if stat.st_size > max_bytes:
        return {
            "path": rel,
            "abs_path": str(target),
            "name": target.name,
            "ext": target.suffix.lower(),
            "size": stat.st_size,
            "mtime": stat.st_mtime,
            "is_binary": False,
            "too_large": True,
            "content": "",
        }

    raw = target.read_bytes()
    if b"\x00" in raw[:8192]:
        return {
            "path": rel,
            "abs_path": str(target),
            "name": target.name,
            "ext": target.suffix.lower(),
            "size": stat.st_size,
            "mtime": stat.st_mtime,
            "is_binary": True,
            "too_large": False,
            "content": "",
        }

    try:
        text = raw.decode("utf-8")
        encoding = "utf-8"
    except UnicodeDecodeError:
        try:
            text = raw.decode("gbk")
            encoding = "gbk"
        except UnicodeDecodeError:
            return {
                "path": rel,
                "abs_path": str(target),
                "name": target.name,
                "ext": target.suffix.lower(),
                "size": stat.st_size,
                "mtime": stat.st_mtime,
                "is_binary": True,
                "too_large": False,
                "content": "",
            }

    return {
        "path": rel,
        "abs_path": str(target),
        "name": target.name,
        "ext": target.suffix.lower(),
        "size": stat.st_size,
        "mtime": stat.st_mtime,
        "encoding": encoding,
        "is_binary": False,
        "too_large": False,
        "content": text,
    }


def write_file_content(
    workspace_root: Path,
    rel_path: str,
    content: str,
    *,
    expected_mtime: float | None = None,
    force: bool = False,
    allowed_workspaces: list[str] | None = None,
    ai_access_mode: str = "workspace_only",
) -> dict[str, Any]:
    """Write text content to a file inside `workspace_root` (or allowed AI scope)."""
    target = resolve_ai_path(
        workspace_root,
        rel_path,
        allowed_workspaces=allowed_workspaces,
        ai_access_mode=ai_access_mode,
        is_write=True,
    )
    if target == workspace_root.resolve():
        raise WorkspaceSecurityError("Cannot overwrite workspace root")
    if target.exists() and target.is_dir():
        raise IsADirectoryError(f"Path is a directory: {rel_path}")

    if target.exists() and expected_mtime is not None and not force:
        current_mtime = target.stat().st_mtime
        if abs(current_mtime - expected_mtime) > 0.01:
            raise FileConflictError(
                f"File '{rel_path}' was modified externally since it was opened."
            )

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    stat = target.stat()
    return {
        "path": to_rel_posix(workspace_root, target),
        "abs_path": str(target),
        "name": target.name,
        "size": stat.st_size,
        "mtime": stat.st_mtime,
    }


def create_entry(
    workspace_root: Path,
    rel_path: str,
    *,
    is_dir: bool = False,
    content: str = "",
) -> dict[str, Any]:
    """Create a new file or directory inside `workspace_root`."""
    target = resolve_workspace_path(workspace_root, rel_path)
    if target == workspace_root.resolve():
        raise WorkspaceSecurityError("Invalid target path")
    if target.exists():
        raise FileExistsError(f"Already exists: {rel_path}")

    if is_dir:
        target.mkdir(parents=True, exist_ok=True)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    stat = target.stat()
    return {
        "path": to_rel_posix(workspace_root, target),
        "is_dir": is_dir,
        "size": 0 if is_dir else stat.st_size,
        "mtime": stat.st_mtime,
    }


def rename_entry(workspace_root: Path, old_rel: str, new_rel: str) -> dict[str, Any]:
    """Rename or move a file/directory within `workspace_root`."""
    src = resolve_workspace_path(workspace_root, old_rel)
    dst = resolve_workspace_path(workspace_root, new_rel)
    root = workspace_root.resolve()
    if src == root or dst == root:
        raise WorkspaceSecurityError("Cannot rename workspace root")
    if not src.exists():
        raise FileNotFoundError(f"Source not found: {old_rel}")
    if dst.exists():
        raise FileExistsError(f"Destination already exists: {new_rel}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    src.rename(dst)
    return {"path": to_rel_posix(workspace_root, dst)}


def delete_entry(workspace_root: Path, rel_path: str) -> dict[str, Any]:
    """Delete a file or directory inside `workspace_root`."""
    target = resolve_workspace_path(workspace_root, rel_path)
    if target == workspace_root.resolve():
        raise WorkspaceSecurityError("Cannot delete workspace root")
    if not target.exists():
        raise FileNotFoundError(f"Path not found: {rel_path}")
    if target.is_dir():
        shutil.rmtree(target)
    else:
        target.unlink()
    return {"deleted": rel_path}


def search_workspace(
    workspace_root: Path,
    query: str,
    *,
    max_results: int = 50,
) -> dict[str, Any]:
    """Search file names and text contents within `workspace_root`."""
    root = workspace_root.resolve()
    needle = query.strip().lower()
    if not needle:
        return {"matches": []}

    matches: list[dict[str, Any]] = []

    def _walk(directory: Path) -> None:
        if len(matches) >= max_results:
            return
        try:
            items = sorted(directory.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower()))
        except OSError:
            return
        for item in items:
            if len(matches) >= max_results:
                return
            if item.name in SKIP_DIRS:
                continue
            rel = to_rel_posix(root, item)
            if item.is_dir():
                _walk(item)
                continue

            if needle in rel.lower():
                matches.append({"path": rel, "line": None, "preview": "[filename match]"})
                if len(matches) >= max_results:
                    return

            try:
                if item.stat().st_size > 512_000:
                    continue
                raw = item.read_bytes()
                if b"\x00" in raw[:4096]:
                    continue
                text = raw.decode("utf-8", errors="ignore")
            except OSError:
                continue

            for idx, line in enumerate(text.splitlines(), start=1):
                if needle in line.lower():
                    matches.append(
                        {
                            "path": rel,
                            "line": idx,
                            "preview": line.strip()[:160],
                        }
                    )
                    if len(matches) >= max_results:
                        return

    _walk(root)
    return {"matches": matches}


def _run_git(workspace_root: Path, args: list[str]) -> tuple[int, str, str]:
    proc = subprocess.run(
        ["git", "-C", str(workspace_root.resolve()), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=10,
    )
    return proc.returncode, proc.stdout, proc.stderr


async def git_status_and_diff(
    workspace_root: Path,
    rel_path: str | None = None,
) -> dict[str, Any]:
    """Return git repository status and unified diff (staged + unstaged)."""

    def _collect() -> dict[str, Any]:
        rc, inside, _ = _run_git(workspace_root, ["rev-parse", "--is-inside-work-tree"])
        if rc != 0 or inside.strip() != "true":
            return {
                "is_git_repo": False,
                "reason": "not_a_repo",
                "message": "当前目录不是 Git 仓库（可在工作区运行 git init 初始化）",
                "branch": "",
                "files": [],
                "diff": "",
            }

        _, branch_out, _ = _run_git(workspace_root, ["rev-parse", "--abbrev-ref", "HEAD"])
        _, status_out, _ = _run_git(workspace_root, ["status", "--porcelain=v1", "-uall"])

        files: list[dict[str, str]] = []
        for line in status_out.splitlines():
            if len(line) < 4:
                continue
            code = line[:2]
            fpath = line[3:].strip()
            if " -> " in fpath:
                fpath = fpath.split(" -> ", 1)[1]
            files.append({"status": code.strip() or "?", "path": fpath})

        diff_args = ["diff", "HEAD"]
        if rel_path:
            safe = resolve_workspace_path(workspace_root, rel_path)
            diff_args.extend(["--", to_rel_posix(workspace_root, safe)])

        rc_diff, diff_out, _ = _run_git(workspace_root, diff_args)
        if rc_diff != 0:
            fallback_args = ["diff"]
            if rel_path:
                safe = resolve_workspace_path(workspace_root, rel_path)
                fallback_args.extend(["--", to_rel_posix(workspace_root, safe)])
            _, diff_out, _ = _run_git(workspace_root, fallback_args)

        return {
            "is_git_repo": True,
            "branch": branch_out.strip(),
            "files": files,
            "diff": diff_out[:200_000],
        }

    return await asyncio.to_thread(_collect)
