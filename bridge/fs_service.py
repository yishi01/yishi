"""Workspace-sandboxed filesystem and Git operations for mobile browsing/editing."""

from __future__ import annotations

import asyncio
import shutil
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


def to_rel_posix(workspace_root: Path, path: Path) -> str:
    root = workspace_root.resolve()
    target = path.resolve()
    if target == root:
        return ""
    return target.relative_to(root).as_posix()


def list_directory(
    workspace_root: Path,
    rel_path: str = "",
    *,
    include_ignored: bool = False,
) -> dict[str, Any]:
    """List immediate children of a directory inside `workspace_root`."""
    target = resolve_workspace_path(workspace_root, rel_path)
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
                "is_dir": is_dir,
                "size": 0 if is_dir else stat.st_size,
                "mtime": stat.st_mtime,
                "ext": "" if is_dir else item.suffix.lower(),
            }
        )

    entries.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))
    return {
        "workspace": str(workspace_root.resolve()),
        "path": to_rel_posix(workspace_root, target),
        "entries": entries,
    }


def read_file_content(
    workspace_root: Path,
    rel_path: str,
    *,
    max_bytes: int = 1_500_000,
) -> dict[str, Any]:
    """Read a text file inside `workspace_root`, safely detecting binaries or huge files."""
    target = resolve_workspace_path(workspace_root, rel_path)
    if not target.exists():
        raise FileNotFoundError(f"File not found: {rel_path}")
    if target.is_dir():
        raise IsADirectoryError(f"Path is a directory: {rel_path}")

    stat = target.stat()
    rel = to_rel_posix(workspace_root, target)
    if stat.st_size > max_bytes:
        return {
            "path": rel,
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
) -> dict[str, Any]:
    """Write text content to a file inside `workspace_root` with optional conflict detection."""
    target = resolve_workspace_path(workspace_root, rel_path)
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
            # Handle repositories with no commits yet
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
