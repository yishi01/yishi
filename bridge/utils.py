"""Shared filesystem, atomic I/O, and path-normalization helpers for DeepSeek Bridge."""

from __future__ import annotations

import os
import threading
from pathlib import Path
from uuid import uuid4


def atomic_write_bytes(target_path: Path, data: bytes) -> None:
    """Atomically write bytes to target_path via a same-directory temp file + os.replace."""
    target = Path(target_path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = target.with_name(
        f".{target.name}.tmp-{os.getpid()}-{threading.get_ident()}-{uuid4().hex[:6]}"
    )
    try:
        tmp_path.write_bytes(data)
        os.replace(tmp_path, target)
    except Exception:
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def atomic_write_text(
    target_path: Path,
    content: str,
    *,
    encoding: str = "utf-8",
) -> None:
    """Atomically write text to target_path via a same-directory temp file + os.replace."""
    atomic_write_bytes(target_path, content.encode(encoding))


def normalize_windows_drive_path(path_str: str | Path) -> str:
    """Normalize bare Windows drive letters ('C:' -> 'C:\\\\') consistently."""
    raw = os.fspath(path_str) if isinstance(path_str, Path) else (path_str or "")
    clean = raw.strip()
    if len(clean) == 2 and clean[0].isalpha() and clean[1] == ":":
        return f"{clean}\\"
    return clean


def cleanup_subagent_files(sessions_dir: Path, session_id: str) -> None:
    """Remove persisted subagent JSON snapshots associated with parent session_id."""
    sub_dir = Path(sessions_dir) / "subagents"
    if not sub_dir.exists():
        return
    prefix = f"{session_id}_"
    for item in sub_dir.glob(f"{prefix}*.json"):
        try:
            item.unlink(missing_ok=True)
        except OSError:
            pass
