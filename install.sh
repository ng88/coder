#!/bin/sh
set -eu

SYSTEM_TARGET=/usr/local/bin/coder
LOCAL_TARGET=${HOME:+$HOME/.local/bin/coder}
CURRENT_TARGET=$PWD/coder
platform=$(uname -s 2>/dev/null || printf 'unknown')

say() {
    printf '%s\n' "$*"
}

platform_notes() {
    if ! command -v python3 >/dev/null 2>&1; then
        say "Warning: python3 is required to run coder and was not found in PATH." >&2
    fi

    if [ "$platform" = Darwin ] && ! command -v sandbox-exec >/dev/null 2>&1; then
        say "Warning: sandbox-exec was not found; coder's default macOS sandbox is unavailable." >&2
    fi
}

finish_install() {
    say "Installed coder to $1"
    platform_notes
}

ask_yes_no() {
    # Prompts must use /dev/tty: stdin may contain the rest of this script when
    # invoked as `curl .../install.sh | sh`.
    prompt=$1
    default=${2:-yes}

    if [ "$default" = yes ]; then
        suffix='[Y/n]'
    else
        suffix='[y/N]'
    fi

    # Keep tty redirection inside a subshell. Some POSIX shells terminate the
    # whole script under `set -e` when a special builtin cannot open /dev/tty.
    if ! answer=$(
        (
            printf '%s %s ' "$prompt" "$suffix" >/dev/tty
            IFS= read -r tty_answer </dev/tty
            printf '%s' "$tty_answer"
        ) 2>/dev/null
    ); then
        return 2
    fi

    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        n|N|no|NO|No) return 1 ;;
        '') [ "$default" = yes ] ;;
        *)
            say "Please answer yes or no."
            ask_yes_no "$prompt" "$default"
            ;;
    esac
}

write_agent() {
    cat <<'__CODER_AGENT_PY_EOF_7C9B5F2A__'
#!/usr/bin/env python3
"""Lightweight remote coding agent.

The agent is started from the project directory it should expose. It connects
outbound to a WebSocket server, prints a temporary token of the form
"machineid:authid", and handles structured command and filesystem operations,
including:

- execute_command
- start_command / poll_command / cancel_command / list_commands
- read_file
- write_file / delete_file / move_file / stat_file
- search_files
- apply_patch
- list_files

By default, shell commands run inside an OS sandbox. Linux uses Bubblewrap with
the project mounted read/write at /workspace, useful system directories mounted
read-only, a temporary HOME/tmp, an isolated PID namespace, and no network
access. macOS uses the native sandbox-exec facility to restrict writes to the
project and temporary directory and to deny network access by default.

Python dependency:
    pip install websockets

Linux dependency for sandboxed command execution:
    bubblewrap (bwrap)

macOS dependency for sandboxed command execution:
    sandbox-exec (included with supported macOS versions)
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import codecs
import fnmatch
import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

try:
    import websockets
    from websockets.exceptions import ConnectionClosed
except ImportError as exc:  # pragma: no cover - startup dependency check
    print(
        "Missing Python dependency: websockets\n"
        "Install it with: python -m pip install websockets",
        file=sys.stderr,
    )
    raise SystemExit(2) from exc


# ---------------------------------------------------------------------------
# Defaults / limits
# ---------------------------------------------------------------------------

DEFAULT_SERVER = os.environ.get("REMOTE_AGENT_SERVER", "wss://coder.nghs.fr/ws/agent")
DEFAULT_TIMEOUT = 30
MAX_RESPONSE_CHARS = 100_000
MAX_SEARCH_RESULTS = 100
MAX_LIST_ENTRIES = 500
MAX_FILE_BYTES = 2_000_000
RECONNECT_MIN_DELAY = 1.0
RECONNECT_MAX_DELAY = 15.0

TEXT_ENCODINGS = ("utf-8", "utf-8-sig")

ANSI_RESET = "\033[0m"
ANSI_BOLD = "\033[1m"
ANSI_GREEN = "\033[32m"
ANSI_YELLOW = "\033[33m"
ANSI_BLUE = "\033[34m"
ANSI_CYAN = "\033[36m"
ANSI_RED = "\033[31m"


def colorize(text: str, *codes: str, stream: Any = sys.stdout) -> str:
    if not getattr(stream, "isatty", lambda: False)():
        return text
    return "".join(codes) + text + ANSI_RESET


def operation_detail(canonical: str, message: dict[str, Any]) -> str:
    def short(value: Any, limit: int = 80) -> str:
        if not isinstance(value, str) or not value:
            return ""
        compact = " ".join(value.split())
        return compact if len(compact) <= limit else compact[: limit - 1] + "…"

    if canonical in {"read_file", "write_file", "delete_file", "stat_file"}:
        return short(message.get("path"))
    if canonical == "move_file":
        source = short(message.get("source"), 40)
        destination = short(message.get("destination"), 40)
        return f"{source} → {destination}" if source and destination else source or destination
    if canonical == "list_files":
        return short(message.get("path")) or "."
    if canonical == "search_files":
        query = short(message.get("query"), 60)
        path = short(message.get("path"), 40)
        return f"{query} @ {path}" if query and path else query or path
    if canonical in {"execute_command", "start_command"}:
        command = short(message.get("command"), 70)
        cwd = short(message.get("cwd"), 30)
        return f"{command} @ {cwd}" if command and cwd else command or cwd
    if canonical in {"poll_command", "cancel_command"}:
        return short(message.get("job_id"), 30)
    if canonical == "apply_patch":
        patch_text = message.get("patch")
        if isinstance(patch_text, str):
            paths = []
            total = 0
            for line in patch_text.splitlines():
                if line.startswith("+++ "):
                    total += 1
                    path = line[4:].strip()
                    if path != "/dev/null" and len(paths) < 3:
                        if path.startswith("b/"):
                            path = path[2:]
                        paths.append(path)
            if paths:
                return ", ".join(paths) + (" …" if total > len(paths) else "")
        return "patch"
    return ""


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class AgentError(Exception):
    """Error that should be returned to the server as a structured error."""

    def __init__(self, code: str, message: str, *, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {"code": self.code, "message": self.message}
        if self.details:
            payload["details"] = self.details
        return payload


# ---------------------------------------------------------------------------
# Token handling
# ---------------------------------------------------------------------------


@dataclass
class AgentIdentity:
    machine_id: str
    auth_id: str

    @classmethod
    def generate(cls) -> "AgentIdentity":
        # token_urlsafe(12) ~= 96 bits; token_urlsafe(32) ~= 256 bits.
        return cls(
            machine_id=secrets.token_urlsafe(12),
            auth_id=secrets.token_urlsafe(32),
        )

    @property
    def token(self) -> str:
        return f"{self.machine_id}:{self.auth_id}"

    def matches(self, candidate: str) -> bool:
        return secrets.compare_digest(self.token, candidate)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def truncate_text(text: str, limit: int = MAX_RESPONSE_CHARS) -> tuple[str, bool]:
    if len(text) <= limit:
        return text, False
    return text[:limit], True


def read_text_file(path: Path) -> str:
    try:
        size = path.stat().st_size
    except OSError as exc:
        raise AgentError("file_not_found", f"Cannot stat file: {path.name}") from exc

    if size > MAX_FILE_BYTES:
        raise AgentError(
            "file_too_large",
            f"File is too large to read safely ({size} bytes).",
            details={"size": size, "max_size": MAX_FILE_BYTES},
        )

    data = path.read_bytes()
    if b"\x00" in data:
        raise AgentError("binary_file", "Refusing to read a binary file as text.")

    for enc in TEXT_ENCODINGS:
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", errors="replace")


def safe_relative_display(path: Path, root: Path) -> str:
    try:
        rel = path.relative_to(root)
    except ValueError:
        return str(path)
    return "." if str(rel) == "." else rel.as_posix()


def is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


class Workspace:
    """Validates all filesystem paths against the startup project root."""

    def __init__(self, root: Path):
        self.root = root.resolve(strict=True)

    def resolve_existing(self, user_path: str | None, *, want_dir: bool | None = None) -> Path:
        raw = user_path or "."
        p = Path(raw)
        if p.is_absolute():
            raise AgentError("invalid_path", "Absolute host paths are not allowed.")

        try:
            candidate = (self.root / p).resolve(strict=True)
        except FileNotFoundError as exc:
            raise AgentError("file_not_found", f"Path does not exist: {raw}") from exc
        except OSError as exc:
            raise AgentError("invalid_path", f"Unable to resolve path: {raw}") from exc
        if not is_relative_to(candidate, self.root):
            raise AgentError("path_outside_workspace", "Path resolves outside the project workspace.")

        if want_dir is True and not candidate.is_dir():
            raise AgentError("invalid_path", "Expected a directory.")
        if want_dir is False and not candidate.is_file():
            raise AgentError("invalid_path", "Expected a file.")
        return candidate

    def resolve_existing_entry(self, user_path: str, *, want_dir: bool | None = None) -> Path:
        """Resolve an existing directory entry without dereferencing its final symlink.

        Parent components are still resolved strictly, so a symlinked parent cannot
        escape the workspace. This is intended for operations such as delete and move
        where the directory entry itself, rather than the symlink target, is mutated.
        """
        p = Path(user_path)
        if p.is_absolute():
            raise AgentError("invalid_path", "Absolute host paths are not allowed.")
        if not p.parts:
            raise AgentError("invalid_path", "Path must identify a workspace entry.")
        if any(part == ".." for part in p.parts):
            raise AgentError("path_outside_workspace", "Parent-directory traversal is not allowed.")

        parent = self.root.joinpath(*p.parts[:-1]) if len(p.parts) > 1 else self.root
        try:
            parent = parent.resolve(strict=True)
        except FileNotFoundError as exc:
            raise AgentError("file_not_found", f"Path does not exist: {user_path}") from exc
        except OSError as exc:
            raise AgentError("invalid_path", f"Unable to resolve path: {user_path}") from exc
        if not is_relative_to(parent, self.root):
            raise AgentError("path_outside_workspace", "Path resolves outside the project workspace.")

        candidate = parent / p.parts[-1]
        if not candidate.exists() and not candidate.is_symlink():
            raise AgentError("file_not_found", f"Path does not exist: {user_path}")

        if want_dir is True and not candidate.is_dir():
            raise AgentError("invalid_path", "Expected a directory.")
        if want_dir is False and not (candidate.is_file() or candidate.is_symlink()):
            raise AgentError("invalid_path", "Expected a file.")
        return candidate

    def resolve_for_write(self, user_path: str) -> Path:
        p = Path(user_path)
        if p.is_absolute():
            raise AgentError("invalid_path", "Absolute host paths are not allowed.")

        # Resolve the nearest existing ancestor so symlinked parent directories cannot
        # escape the workspace. Then append the non-existing suffix lexically.
        current = self.root
        for part in p.parts:
            if part in ("", "."):
                continue
            if part == "..":
                raise AgentError("path_outside_workspace", "Parent-directory traversal is not allowed.")
            next_path = current / part
            if next_path.exists() or next_path.is_symlink():
                next_path = next_path.resolve(strict=True)
                if not is_relative_to(next_path, self.root):
                    raise AgentError("path_outside_workspace", "Path resolves outside the project workspace.")
            current = next_path

        # Resolve the parent again if it exists, protecting against final symlink races
        # as far as practical without openat2-style kernel primitives.
        parent = current.parent
        if parent.exists():
            parent_resolved = parent.resolve(strict=True)
            if not is_relative_to(parent_resolved, self.root):
                raise AgentError("path_outside_workspace", "Parent resolves outside the project workspace.")
            current = parent_resolved / current.name

        return current

    def to_sandbox_path(self, host_path: Path) -> str:
        rel = host_path.relative_to(self.root)
        return "/workspace" if str(rel) == "." else f"/workspace/{rel.as_posix()}"


# ---------------------------------------------------------------------------
# Unified diff application
# ---------------------------------------------------------------------------


_HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


@dataclass
class PatchHunk:
    old_start: int
    old_count: int
    new_start: int
    new_count: int
    lines: list[str]


@dataclass
class FilePatch:
    old_path: str
    new_path: str
    hunks: list[PatchHunk]


def _clean_patch_path(value: str) -> str:
    value = value.strip()
    if value == "/dev/null":
        return value
    value = value.split("\t", 1)[0]
    if value.startswith("a/") or value.startswith("b/"):
        value = value[2:]
    return value


def _parse_apply_patch_format(patch_text: str) -> list[FilePatch]:
    """Parse the lightweight *** Begin Patch format used by many coding agents."""

    lines = patch_text.splitlines(keepends=True)
    if not lines or lines[0].strip() != "*** Begin Patch":
        raise AgentError("invalid_patch", "Malformed apply-patch envelope.")

    patches: list[FilePatch] = []
    i = 1
    while i < len(lines):
        marker = lines[i].rstrip("\r\n")
        if marker == "*** End Patch":
            if i != len(lines) - 1:
                trailing = "".join(lines[i + 1 :]).strip()
                if trailing:
                    raise AgentError("invalid_patch", "Unexpected content after *** End Patch.")
            break

        action = None
        path = None
        for prefix, candidate in (
            ("*** Add File: ", "add"),
            ("*** Update File: ", "update"),
            ("*** Delete File: ", "delete"),
        ):
            if marker.startswith(prefix):
                action = candidate
                path = marker[len(prefix) :].strip()
                break
        if action is None or not path:
            raise AgentError("invalid_patch", f"Unexpected apply-patch directive: {marker}")
        i += 1

        if action == "delete":
            patches.append(FilePatch(path, "/dev/null", []))
            continue

        hunks: list[PatchHunk] = []
        if action == "add":
            body: list[str] = []
            while i < len(lines) and not lines[i].startswith("*** "):
                line = lines[i]
                if not line.startswith("+"):
                    raise AgentError("invalid_patch", "Added-file lines must start with '+'.")
                body.append(line)
                i += 1
            hunks.append(PatchHunk(0, 0, 1, len(body), body))
            patches.append(FilePatch("/dev/null", path, hunks))
            continue

        while i < len(lines) and not lines[i].startswith("*** "):
            header = lines[i]
            if not header.startswith("@@"):
                raise AgentError("invalid_patch", f"Expected @@ hunk header, got: {header.rstrip()}")
            match = _HUNK_RE.match(header)
            if match:
                old_start = int(match.group(1))
                new_start = int(match.group(3))
            else:
                # A bare @@ hunk is intentionally unanchored. The apply phase
                # will locate its old-side context uniquely in the remaining
                # source instead of assuming line 1.
                old_start = -1
                new_start = -1
            i += 1

            body: list[str] = []
            while i < len(lines) and not lines[i].startswith("@@") and not lines[i].startswith("*** "):
                line = lines[i]
                if line.startswith((" ", "+", "-")):
                    body.append(line)
                elif line.startswith("\\ No newline at end of file"):
                    pass
                else:
                    raise AgentError("invalid_patch", f"Unexpected patch line: {line.rstrip()}")
                i += 1
            old_count = sum(1 for line in body if line[:1] in (" ", "-"))
            new_count = sum(1 for line in body if line[:1] in (" ", "+"))
            hunks.append(PatchHunk(old_start, old_count, new_start, new_count, body))

        if not hunks:
            raise AgentError("invalid_patch", f"Update for {path} contains no hunks.")
        patches.append(FilePatch(path, path, hunks))
    else:
        raise AgentError("invalid_patch", "Missing *** End Patch marker.")

    if not patches:
        raise AgentError("invalid_patch", "Patch contains no file operations.")
    return patches


def parse_unified_diff(patch_text: str) -> list[FilePatch]:
    if patch_text.lstrip().startswith("*** Begin Patch"):
        return _parse_apply_patch_format(patch_text.lstrip())

    lines = patch_text.splitlines(keepends=True)
    patches: list[FilePatch] = []
    i = 0

    while i < len(lines):
        if not lines[i].startswith("--- "):
            i += 1
            continue

        old_path = _clean_patch_path(lines[i][4:].rstrip("\n"))
        i += 1
        if i >= len(lines) or not lines[i].startswith("+++ "):
            raise AgentError("invalid_patch", "Expected +++ header after --- header.")
        new_path = _clean_patch_path(lines[i][4:].rstrip("\n"))
        i += 1

        hunks: list[PatchHunk] = []
        while i < len(lines):
            if lines[i].startswith("--- "):
                break
            if lines[i].startswith("diff --git ") or lines[i].startswith("index "):
                i += 1
                continue
            if not lines[i].startswith("@@ "):
                i += 1
                continue

            match = _HUNK_RE.match(lines[i])
            if not match:
                raise AgentError("invalid_patch", f"Malformed hunk header: {lines[i].strip()}")
            old_start = int(match.group(1))
            old_count = int(match.group(2) or "1")
            new_start = int(match.group(3))
            new_count = int(match.group(4) or "1")
            i += 1

            hunk_lines: list[str] = []
            while i < len(lines):
                line = lines[i]
                if line.startswith("@@ ") or line.startswith("--- "):
                    break
                if line.startswith("diff --git "):
                    break
                if line.startswith((" ", "+", "-")):
                    hunk_lines.append(line)
                elif line.startswith("\\ No newline at end of file"):
                    pass
                else:
                    raise AgentError("invalid_patch", f"Unexpected patch line: {line.rstrip()}")
                i += 1

            hunks.append(PatchHunk(old_start, old_count, new_start, new_count, hunk_lines))

        patches.append(FilePatch(old_path, new_path, hunks))

    if not patches:
        raise AgentError("invalid_patch", "No unified-diff file headers were found.")
    return patches


def _find_hunk_target(source: list[str], hunk: PatchHunk, minimum_index: int) -> int:
    unanchored = hunk.old_start == -1
    expected = minimum_index if unanchored else max(hunk.old_start - 1, 0)
    old_lines = [line[1:] for line in hunk.lines if line[:1] in (" ", "-")]
    if not old_lines:
        if unanchored:
            raise AgentError(
                "invalid_patch",
                "Bare @@ hunks must contain context or removed lines so their location is unambiguous.",
            )
        if expected < minimum_index or expected > len(source):
            raise AgentError("patch_conflict", "Patch hunk position is inconsistent with file content.")
        return expected
    candidates = [
        start
        for start in range(minimum_index, len(source) - len(old_lines) + 1)
        if source[start : start + len(old_lines)] == old_lines
    ]
    if not candidates:
        actual_start = min(max(expected, 0), max(len(source) - 1, 0))
        actual_excerpt = source[actual_start : actual_start + max(len(old_lines), 3)]
        raise AgentError(
            "patch_conflict",
            "Patch context does not match current file content.",
            details={
                "expected_line": hunk.old_start,
                "expected_excerpt": [line.rstrip("\r\n") for line in old_lines[:8]],
                "actual_excerpt": [line.rstrip("\r\n") for line in actual_excerpt[:8]],
                "line_endings": "CRLF" if any(line.endswith("\r\n") for line in source) else "LF",
            },
        )
    if unanchored and len(candidates) != 1:
        raise AgentError(
            "patch_conflict",
            "Bare @@ hunk context matches multiple locations; add more context or explicit line numbers.",
            details={
                "candidate_lines": [start + 1 for start in candidates[:20]],
                "match_count": len(candidates),
            },
        )
    return min(candidates, key=lambda start: (abs(start - expected), start))


def _apply_hunks_to_text(original: str, hunks: list[PatchHunk]) -> str:
    source = original.splitlines(keepends=True)
    output: list[str] = []
    src_index = 0

    for hunk in hunks:
        target_index = _find_hunk_target(source, hunk, src_index)

        output.extend(source[src_index:target_index])
        src_index = target_index

        old_seen = 0
        new_seen = 0
        for line in hunk.lines:
            prefix = line[:1]
            content = line[1:]

            if prefix == " ":
                if src_index >= len(source) or source[src_index] != content:
                    raise AgentError("patch_conflict", "Patch context does not match current file content.")
                output.append(source[src_index])
                src_index += 1
                old_seen += 1
                new_seen += 1
            elif prefix == "-":
                if src_index >= len(source) or source[src_index] != content:
                    raise AgentError("patch_conflict", "Patch removal does not match current file content.")
                src_index += 1
                old_seen += 1
            elif prefix == "+":
                output.append(content)
                new_seen += 1

        if old_seen != hunk.old_count or new_seen != hunk.new_count:
            raise AgentError(
                "invalid_patch",
                "Patch hunk line counts do not match its header.",
                details={
                    "expected_old": hunk.old_count,
                    "actual_old": old_seen,
                    "expected_new": hunk.new_count,
                    "actual_new": new_seen,
                },
            )

    output.extend(source[src_index:])
    return "".join(output)


def apply_unified_patch(workspace: Workspace, patch_text: str) -> list[str]:
    patches = parse_unified_diff(patch_text)

    # First phase: validate and compute every result before writing anything.
    planned: list[tuple[str, Path, str | None]] = []
    changed_files: list[str] = []

    for fp in patches:
        old_path = fp.old_path
        new_path = fp.new_path

        if old_path == "/dev/null" and new_path == "/dev/null":
            raise AgentError("invalid_patch", "Both patch paths cannot be /dev/null.")

        if old_path == "/dev/null":
            target = workspace.resolve_for_write(new_path)
            if target.exists():
                raise AgentError("patch_conflict", f"Cannot create existing file: {new_path}")
            original = ""
            result = _apply_hunks_to_text(original, fp.hunks)
            planned.append(("write", target, result))
            changed_files.append(new_path)
            continue

        source = workspace.resolve_existing(old_path, want_dir=False)
        original = read_text_file(source)
        result = _apply_hunks_to_text(original, fp.hunks)

        if new_path == "/dev/null":
            planned.append(("delete", source, None))
            changed_files.append(old_path)
            continue

        target = workspace.resolve_for_write(new_path)
        if target != source and target.exists():
            raise AgentError("patch_conflict", f"Patch destination already exists: {new_path}")
        if target == source:
            planned.append(("replace", source, result))
        else:
            # Write the destination first, then remove the old path. Validation above
            # guarantees the destination does not already exist.
            planned.append(("move_write", target, result))
            planned.append(("delete", source, None))
        changed_files.append(new_path)

    expected_postimages: dict[Path, str | None] = {}
    for action, path, content in planned:
        expected_postimages[path] = content if action != "delete" else None

    # Second phase: perform writes atomically per file where possible.
    for action, path, content in planned:
        if action in ("write", "replace", "move_write"):
            assert content is not None
            path.parent.mkdir(parents=True, exist_ok=True)
            mode = None
            if path.exists():
                mode = stat.S_IMODE(path.stat().st_mode)
            fd, tmp_name = tempfile.mkstemp(prefix=".agent-patch-", dir=str(path.parent))
            try:
                with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
                    f.write(content)
                if mode is not None:
                    os.chmod(tmp_name, mode)
                os.replace(tmp_name, path)
            finally:
                if os.path.exists(tmp_name):
                    os.unlink(tmp_name)
        elif action == "delete":
            path.unlink()

    for path, expected in expected_postimages.items():
        relative = path.relative_to(workspace.root)
        if expected is None:
            if path.exists():
                raise AgentError(
                    "patch_verification_failed",
                    f"Patch deletion could not be verified: {relative}",
                )
            continue
        if not path.is_file():
            raise AgentError(
                "patch_verification_failed",
                f"Patched file is missing from the workspace: {relative}",
            )
        if read_text_file(path) != expected:
            raise AgentError(
                "patch_verification_failed",
                f"Patched file content could not be verified: {relative}",
            )
    return changed_files


# ---------------------------------------------------------------------------
# Agent tools
# ---------------------------------------------------------------------------


@dataclass
class CommandJob:
    job_id: str
    command: str
    cwd: str
    proc: asyncio.subprocess.Process
    started_at: float
    status: str = "running"
    finished_at: float | None = None
    exit_code: int | None = None
    stdout: str = ""
    stderr: str = ""
    stdout_start: int = 0
    stderr_start: int = 0
    cancel_requested: bool = False
    condition: asyncio.Condition = field(default_factory=asyncio.Condition)
    tasks: list[asyncio.Task[Any]] = field(default_factory=list)


class AgentTools:
    def __init__(self, workspace: Workspace, *, sandbox: bool, network: bool):
        self.workspace = workspace
        self.sandbox = sandbox
        self.network = network
        self.command_jobs: dict[str, CommandJob] = {}

    def _command_argv_and_cwd(self, command: str, cwd_value: Any) -> tuple[list[str], str, str]:
        cwd_host = self.workspace.resolve_existing(cwd_value or ".", want_dir=True)
        cwd_sandbox = self.workspace.to_sandbox_path(cwd_host)
        if self.sandbox:
            if sys.platform == "darwin":
                argv = self._build_macos_sandbox_command(command)
                proc_cwd = str(cwd_host)
            else:
                argv = self._build_bwrap_command(command, cwd_sandbox)
                proc_cwd = str(self.workspace.root)
        else:
            if os.name == "nt":
                argv = [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/s", "/c", command]
            else:
                argv = ["/bin/bash", "-lc", command]
            proc_cwd = str(cwd_host)
        return argv, proc_cwd, safe_relative_display(cwd_host, self.workspace.root)

    @staticmethod
    def _subprocess_session_kwargs() -> dict[str, Any]:
        if os.name == "nt":
            new_process_group = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200)
            return {"creationflags": new_process_group}
        return {"start_new_session": True}

    def _command_env(self) -> dict[str, str]:
        if not self.sandbox:
            return os.environ.copy()
        return self._minimal_env()

    async def execute_command(self, payload: dict[str, Any]) -> dict[str, Any]:
        command = payload.get("command")
        if not isinstance(command, str) or not command.strip():
            raise AgentError("invalid_request", "command must be a non-empty string.")

        timeout = payload.get("timeout", DEFAULT_TIMEOUT)
        if not isinstance(timeout, int) or isinstance(timeout, bool) or timeout < 0:
            raise AgentError("invalid_request", "timeout must be an integer >= 0.")

        argv, proc_cwd, _ = self._command_argv_and_cwd(command, payload.get("cwd"))

        env = self._command_env()
        started = time.monotonic()

        try:
            proc = await asyncio.create_subprocess_exec(
                *argv,
                cwd=proc_cwd,
                env=env,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                **self._subprocess_session_kwargs(),
            )
        except FileNotFoundError as exc:
            raise AgentError("execution_failed", f"Unable to start command: {exc}") from exc

        stdout_task = asyncio.create_task(self._read_limited_stream(proc.stdout))
        stderr_task = asyncio.create_task(self._read_limited_stream(proc.stderr))
        timed_out = False
        try:
            if timeout == 0:
                await proc.wait()
            else:
                await asyncio.wait_for(proc.wait(), timeout=timeout)
        except asyncio.TimeoutError:
            timed_out = True
            await self._terminate_process_tree(proc)
        stdout_b, stdout_overflow = await stdout_task
        stderr_b, stderr_overflow = await stderr_task

        stdout = stdout_b.decode("utf-8", errors="replace")
        stderr = stderr_b.decode("utf-8", errors="replace")
        stdout, out_trunc = truncate_text(stdout)
        stderr, err_trunc = truncate_text(stderr)

        return {
            "stdout": stdout,
            "stderr": stderr,
            "exit_code": None if timed_out else proc.returncode,
            "timed_out": timed_out,
            "truncated": bool(stdout_overflow or stderr_overflow or out_trunc or err_trunc),
            "duration_ms": int((time.monotonic() - started) * 1000),
        }

    async def start_command(self, payload: dict[str, Any]) -> dict[str, Any]:
        command = payload.get("command")
        if not isinstance(command, str) or not command.strip():
            raise AgentError("invalid_request", "command must be a non-empty string.")

        self._prune_command_jobs()
        running = sum(1 for job in self.command_jobs.values() if job.status == "running")
        if running >= 10:
            raise AgentError("too_many_jobs", "At most 10 long-running commands may run concurrently.")

        argv, proc_cwd, relative_cwd = self._command_argv_and_cwd(command, payload.get("cwd"))
        try:
            proc = await asyncio.create_subprocess_exec(
                *argv,
                cwd=proc_cwd,
                env=self._command_env(),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                **self._subprocess_session_kwargs(),
            )
        except FileNotFoundError as exc:
            raise AgentError("execution_failed", f"Unable to start command: {exc}") from exc

        job_id = secrets.token_urlsafe(12)
        job = CommandJob(job_id, command, relative_cwd, proc, time.monotonic())
        self.command_jobs[job_id] = job
        job.tasks = [
            asyncio.create_task(self._capture_job_stream(job, proc.stdout, "stdout")),
            asyncio.create_task(self._capture_job_stream(job, proc.stderr, "stderr")),
        ]
        job.tasks.append(asyncio.create_task(self._monitor_command_job(job)))
        return {"job_id": job_id, "status": "running", "command": command, "cwd": relative_cwd}

    async def poll_command(self, payload: dict[str, Any]) -> dict[str, Any]:
        job = self._get_command_job(payload.get("job_id"))
        stdout_offset = self._job_offset(payload.get("stdout_offset", 0), "stdout_offset")
        stderr_offset = self._job_offset(payload.get("stderr_offset", 0), "stderr_offset")
        wait_seconds = payload.get("wait_seconds", 0)
        if not isinstance(wait_seconds, int) or isinstance(wait_seconds, bool) or not 0 <= wait_seconds <= 30:
            raise AgentError("invalid_request", "wait_seconds must be an integer between 0 and 30.")

        if wait_seconds:
            async with job.condition:
                if job.status == "running" and not self._job_has_new_output(job, stdout_offset, stderr_offset):
                    try:
                        await asyncio.wait_for(job.condition.wait(), timeout=wait_seconds)
                    except asyncio.TimeoutError:
                        pass

        return self._command_job_poll_result(job, stdout_offset, stderr_offset)

    async def cancel_command(self, payload: dict[str, Any]) -> dict[str, Any]:
        job = self._get_command_job(payload.get("job_id"))
        if job.status == "running":
            job.cancel_requested = True
            await self._terminate_process_tree(job.proc)
            await job.tasks[-1]
        return self._command_job_summary(job)

    async def list_commands(self, payload: dict[str, Any]) -> dict[str, Any]:
        self._prune_command_jobs()
        jobs = sorted(self.command_jobs.values(), key=lambda job: job.started_at, reverse=True)
        return {"jobs": [self._command_job_summary(job) for job in jobs]}

    async def shutdown_command_jobs(self) -> None:
        running = [job for job in self.command_jobs.values() if job.status == "running"]
        for job in running:
            job.cancel_requested = True
            await self._terminate_process_tree(job.proc)
        if running:
            await asyncio.gather(*(job.tasks[-1] for job in running), return_exceptions=True)

    async def read_file(self, payload: dict[str, Any]) -> dict[str, Any]:
        path_value = payload.get("path")
        if not isinstance(path_value, str) or not path_value:
            raise AgentError("invalid_request", "path must be a non-empty string.")
        path = self.workspace.resolve_existing(path_value, want_dir=False)
        text = read_text_file(path)
        lines = text.splitlines(keepends=True)
        total = len(lines)

        start_line = payload.get("start_line", 1)
        end_line = payload.get("end_line", total if total else 1)
        if not isinstance(start_line, int) or start_line < 1:
            raise AgentError("invalid_request", "start_line must be an integer >= 1.")
        if not isinstance(end_line, int) or end_line < start_line:
            raise AgentError("invalid_request", "end_line must be an integer >= start_line.")

        selected = "".join(lines[start_line - 1 : end_line])
        selected, truncated = truncate_text(selected)

        return {
            "path": safe_relative_display(path, self.workspace.root),
            "start_line": start_line,
            "end_line": min(end_line, total),
            "total_lines": total,
            "content": selected,
            "truncated": truncated or end_line < total,
        }

    async def write_file(self, payload: dict[str, Any]) -> dict[str, Any]:
        path_value = payload.get("path")
        content = payload.get("content")
        if not isinstance(path_value, str) or not path_value:
            raise AgentError("invalid_request", "path must be a non-empty string.")
        if not isinstance(content, str):
            raise AgentError("invalid_request", "content must be a string.")
        data = content.encode("utf-8")
        if len(data) > MAX_FILE_BYTES:
            raise AgentError("invalid_request", "content exceeds the maximum file size.")
        overwrite = payload.get("overwrite", False)
        create_parents = payload.get("create_parents", False)
        if not isinstance(overwrite, bool) or not isinstance(create_parents, bool):
            raise AgentError("invalid_request", "overwrite and create_parents must be booleans.")
        target = self.workspace.resolve_for_write(path_value)
        if target.exists() and not overwrite:
            raise AgentError("already_exists", "Target file already exists; set overwrite=true to replace it.")
        if target.exists() and not target.is_file():
            raise AgentError("invalid_path", "Target exists and is not a regular file.")
        original_mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else None
        if not target.parent.exists():
            if not create_parents:
                raise AgentError("invalid_path", "Parent directory does not exist.")
            target.parent.mkdir(parents=True, exist_ok=True)
            target = self.workspace.resolve_for_write(path_value)
        fd, tmp_name = tempfile.mkstemp(prefix=f".{target.name}.", dir=str(target.parent))
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            if original_mode is not None:
                os.chmod(tmp_name, original_mode)
            os.replace(tmp_name, target)
        finally:
            if os.path.exists(tmp_name):
                os.unlink(tmp_name)
        actual = target.read_bytes()
        if actual != data:
            raise AgentError("write_verification_failed", "Written file content could not be verified.")
        return {"path": safe_relative_display(target, self.workspace.root), "bytes": len(actual), "sha256": hashlib.sha256(actual).hexdigest()}

    async def delete_file(self, payload: dict[str, Any]) -> dict[str, Any]:
        path_value = payload.get("path")
        if not isinstance(path_value, str) or not path_value:
            raise AgentError("invalid_request", "path must be a non-empty string.")
        target = self.workspace.resolve_existing_entry(path_value, want_dir=False)
        display = safe_relative_display(target, self.workspace.root)
        target.unlink()
        if target.exists() or target.is_symlink():
            raise AgentError("delete_verification_failed", "Deleted file is still present in the workspace.")
        return {"path": display, "deleted": True}

    async def move_file(self, payload: dict[str, Any]) -> dict[str, Any]:
        source_value = payload.get("source")
        destination_value = payload.get("destination")
        overwrite = payload.get("overwrite", False)
        create_parents = payload.get("create_parents", False)
        if not isinstance(source_value, str) or not source_value:
            raise AgentError("invalid_request", "source must be a non-empty string.")
        if not isinstance(destination_value, str) or not destination_value:
            raise AgentError("invalid_request", "destination must be a non-empty string.")
        if not isinstance(overwrite, bool) or not isinstance(create_parents, bool):
            raise AgentError("invalid_request", "overwrite and create_parents must be booleans.")
        source = self.workspace.resolve_existing_entry(source_value, want_dir=False)
        destination = self.workspace.resolve_for_write(destination_value)
        if source == destination:
            raise AgentError("invalid_request", "source and destination must be different.")
        if destination.exists() and not overwrite:
            raise AgentError("already_exists", "Destination already exists; set overwrite=true to replace it.")
        if destination.exists() and not destination.is_file():
            raise AgentError("invalid_path", "Destination exists and is not a regular file.")
        if not destination.parent.exists():
            if not create_parents:
                raise AgentError("invalid_path", "Destination parent directory does not exist.")
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination = self.workspace.resolve_for_write(destination_value)
        before_size, before_hash, before_link = self._entry_fingerprint(source)
        os.replace(source, destination)
        if source.exists() or source.is_symlink():
            raise AgentError("move_verification_failed", "Moved file could not be verified.")
        try:
            after_size, after_hash, after_link = self._entry_fingerprint(destination)
        except AgentError as exc:
            raise AgentError("move_verification_failed", "Moved file could not be verified.") from exc
        if (after_size, after_hash, after_link) != (before_size, before_hash, before_link):
            raise AgentError("move_verification_failed", "Moved file could not be verified.")
        return {
            "source": source_value,
            "destination": safe_relative_display(destination, self.workspace.root),
            "bytes": before_size,
            "sha256": before_hash,
        }

    async def stat_file(self, payload: dict[str, Any]) -> dict[str, Any]:
        path_value = payload.get("path")
        if not isinstance(path_value, str) or not path_value:
            raise AgentError("invalid_request", "path must be a non-empty string.")
        path = self.workspace.resolve_existing(path_value, want_dir=None)
        info = path.stat()
        result: dict[str, Any] = {"path": safe_relative_display(path, self.workspace.root), "type": "directory" if path.is_dir() else "file", "size": info.st_size, "mtime_ns": info.st_mtime_ns}
        if path.is_file():
            digest = hashlib.sha256()
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
            result["sha256"] = digest.hexdigest()
        else:
            result["sha256"] = None
        return result

    async def search_files(self, payload: dict[str, Any]) -> dict[str, Any]:
        query = payload.get("query")
        if not isinstance(query, str) or not query:
            raise AgentError("invalid_request", "query must be a non-empty string.")

        base = self.workspace.resolve_existing(payload.get("path") or ".", want_dir=None)
        glob_pat = payload.get("glob")
        if glob_pat is not None and not isinstance(glob_pat, str):
            raise AgentError("invalid_request", "glob must be a string when provided.")

        max_results = payload.get("max_results", MAX_SEARCH_RESULTS)
        if not isinstance(max_results, int) or max_results < 1:
            raise AgentError("invalid_request", "max_results must be an integer >= 1.")
        max_results = min(max_results, MAX_SEARCH_RESULTS)

        matches: list[dict[str, Any]] = []
        truncated = False

        files: Iterable[Path]
        if base.is_file():
            files = [base]
        else:
            files = self._iter_files(base)

        for file_path in files:
            rel = safe_relative_display(file_path, self.workspace.root)
            if glob_pat and not fnmatch.fnmatch(rel, glob_pat) and not fnmatch.fnmatch(file_path.name, glob_pat):
                continue
            try:
                if file_path.stat().st_size > MAX_FILE_BYTES:
                    continue
                data = file_path.read_bytes()
                if b"\x00" in data:
                    continue
                text = data.decode("utf-8", errors="replace")
            except (OSError, UnicodeError):
                continue

            for line_no, line in enumerate(text.splitlines(), 1):
                if query in line:
                    matches.append({"path": rel, "line": line_no, "text": line[:2000]})
                    if len(matches) >= max_results:
                        truncated = True
                        break
            if truncated:
                break

        return {"matches": matches, "truncated": truncated}

    async def apply_patch(self, payload: dict[str, Any]) -> dict[str, Any]:
        patch = payload.get("patch")
        if not isinstance(patch, str) or not patch.strip():
            raise AgentError("invalid_request", "patch must be a non-empty unified diff string.")
        if len(patch) > MAX_RESPONSE_CHARS * 4:
            raise AgentError("invalid_request", "Patch is too large.")

        changed = apply_unified_patch(self.workspace, patch)
        return {"applied": True, "files_changed": changed}

    async def list_files(self, payload: dict[str, Any]) -> dict[str, Any]:
        base = self.workspace.resolve_existing(payload.get("path") or ".", want_dir=None)
        depth = payload.get("depth", 2)
        if not isinstance(depth, int) or depth < 0:
            raise AgentError("invalid_request", "depth must be an integer >= 0.")
        depth = min(depth, 20)

        max_entries = payload.get("max_entries", MAX_LIST_ENTRIES)
        if not isinstance(max_entries, int) or max_entries < 1:
            raise AgentError("invalid_request", "max_entries must be an integer >= 1.")
        max_entries = min(max_entries, MAX_LIST_ENTRIES)

        entries: list[dict[str, str]] = []
        truncated = False

        if base.is_file():
            return {
                "entries": [{"path": safe_relative_display(base, self.workspace.root), "type": "file"}],
                "truncated": False,
            }

        base_depth = len(base.parts)
        for root, dirs, files in os.walk(base, followlinks=False):
            root_path = Path(root)
            current_depth = len(root_path.parts) - base_depth
            if current_depth >= depth:
                dirs[:] = []

            dirs[:] = sorted(d for d in dirs if d not in {".git"})
            for name in dirs:
                p = root_path / name
                kind = "symlink" if p.is_symlink() else "directory"
                entries.append({"path": safe_relative_display(p, self.workspace.root), "type": kind})
                if len(entries) >= max_entries:
                    truncated = True
                    break
            if truncated:
                break

            for name in sorted(files):
                p = root_path / name
                kind = "symlink" if p.is_symlink() else "file"
                entries.append({"path": safe_relative_display(p, self.workspace.root), "type": kind})
                if len(entries) >= max_entries:
                    truncated = True
                    break
            if truncated:
                break

        return {"entries": entries, "truncated": truncated}

    @staticmethod
    def _entry_fingerprint(path: Path) -> tuple[int, str, str | None]:
        """Return a bounded-memory fingerprint for a regular file or symlink."""
        if path.is_symlink():
            link_target = os.readlink(path)
            data = os.fsencode(link_target)
            return len(data), hashlib.sha256(data).hexdigest(), link_target
        if not path.is_file():
            raise AgentError("invalid_path", "Expected a regular file or symlink.")
        digest = hashlib.sha256()
        size = 0
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                size += len(chunk)
                digest.update(chunk)
        return size, digest.hexdigest(), None

    def _iter_files(self, base: Path) -> Iterable[Path]:
        for root, dirs, files in os.walk(base, followlinks=False):
            # Avoid the most common high-volume metadata directory by default.
            dirs[:] = [d for d in dirs if d != ".git"]
            for name in files:
                p = Path(root) / name
                try:
                    resolved = p.resolve(strict=True)
                except OSError:
                    continue
                if not is_relative_to(resolved, self.workspace.root):
                    continue
                if resolved.is_file():
                    yield resolved

    def _minimal_env(self) -> dict[str, str]:
        if os.name == "nt":
            keys = (
                "PATH",
                "Path",
                "PATHEXT",
                "SystemRoot",
                "SYSTEMROOT",
                "COMSPEC",
                "TEMP",
                "TMP",
                "USERPROFILE",
                "USERNAME",
            )
            env = {key: os.environ[key] for key in keys if os.environ.get(key)}
            env.setdefault("TEMP", tempfile.gettempdir())
            env.setdefault("TMP", tempfile.gettempdir())
            return env

        sandbox_home = "/tmp/home"
        path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        if sys.platform == "darwin":
            sandbox_home = tempfile.gettempdir()
            # Apple Silicon Homebrew installs under /opt/homebrew by default.
            # Keep the environment deterministic while exposing the two common
            # macOS package-manager executable locations.
            path = "/opt/homebrew/sbin:/opt/homebrew/bin:" + path
        env = {
            "PATH": path,
            "HOME": sandbox_home if self.sandbox else tempfile.gettempdir(),
            "LANG": os.environ.get("LANG", "C.UTF-8"),
            "LC_ALL": os.environ.get("LC_ALL", ""),
            "TERM": os.environ.get("TERM", "dumb"),
        }
        return {k: v for k, v in env.items() if v}

    def _build_bwrap_command(self, command: str, cwd: str) -> list[str]:
        argv = [
            "bwrap",
            "--die-with-parent",
            "--new-session",
            "--unshare-pid",
            "--unshare-ipc",
            "--unshare-uts",
            "--proc",
            "/proc",
            "--dev",
            "/dev",
            "--tmpfs",
            "/tmp",
            "--dir",
            "/tmp/home",
            "--bind",
            str(self.workspace.root),
            "/workspace",
        ]

        if not self.network:
            argv.append("--unshare-net")

        # Mount only common executable/runtime trees. Do NOT expose the complete
        # host /etc: it may contain machine secrets unrelated to the project.
        for host_path in ("/usr", "/bin", "/sbin", "/lib", "/lib64"):
            if os.path.exists(host_path):
                argv.extend(["--ro-bind", host_path, host_path])

        # Some distributions route executable symlinks through /etc/alternatives.
        # Create an otherwise-empty /etc and expose only narrowly useful pieces.
        argv.extend(["--dir", "/etc"])
        if os.path.exists("/etc/alternatives"):
            argv.extend(["--ro-bind", "/etc/alternatives", "/etc/alternatives"])

        # Network-enabled commands commonly need DNS and CA roots. Expose only
        # those specific host files/directories rather than all of /etc.
        if self.network:
            for host_path in (
                "/etc/resolv.conf",
                "/etc/hosts",
                "/etc/nsswitch.conf",
                "/etc/ssl",
                "/etc/ca-certificates",
                "/etc/pki",
            ):
                if os.path.exists(host_path):
                    argv.extend(["--ro-bind", host_path, host_path])

        argv.extend(["--chdir", cwd, "/bin/bash", "-lc", command])
        return argv

    def _build_macos_sandbox_command(self, command: str) -> list[str]:
        # sandbox-exec/Seatbelt profiles are not namespace sandboxes like
        # Bubblewrap. Keep normal system reads/process execution available, but
        # restrict writes to the exposed project and temporary directory and
        # deny network access unless explicitly requested.
        workspace = json.dumps(str(self.workspace.root))
        tmp_dir = json.dumps(tempfile.gettempdir())
        profile = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            f"(allow file-write* (subpath {workspace}))",
            f"(allow file-write* (subpath {tmp_dir}))",
        ]
        if not self.network:
            profile.append("(deny network*)")
        return ["sandbox-exec", "-p", "\n".join(profile), "/bin/bash", "-lc", command]

    async def _terminate_process_tree(self, proc: asyncio.subprocess.Process) -> None:
        if proc.returncode is not None:
            return

        if os.name == "nt":
            taskkill = shutil.which("taskkill")
            if taskkill:
                killer = await asyncio.create_subprocess_exec(
                    taskkill,
                    "/PID",
                    str(proc.pid),
                    "/T",
                    "/F",
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                await killer.wait()
            else:
                proc.terminate()
            await proc.wait()
            return

        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return

        try:
            await asyncio.wait_for(proc.wait(), timeout=2.0)
            return
        except asyncio.TimeoutError:
            pass

        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        await proc.wait()

    @staticmethod
    async def _read_limited_stream(
        stream: asyncio.StreamReader | None,
    ) -> tuple[bytes, bool]:
        if stream is None:
            return b"", False

        byte_limit = MAX_RESPONSE_CHARS * 4
        kept = bytearray()
        overflow = False
        while True:
            chunk = await stream.read(64 * 1024)
            if not chunk:
                break
            remaining = byte_limit - len(kept)
            if remaining > 0:
                kept.extend(chunk[:remaining])
            if len(chunk) > remaining:
                overflow = True

        return bytes(kept), overflow

    async def _capture_job_stream(
        self,
        job: CommandJob,
        stream: asyncio.StreamReader | None,
        name: str,
    ) -> None:
        if stream is None:
            return

        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        while True:
            chunk = await stream.read(64 * 1024)
            if not chunk:
                text = decoder.decode(b"", final=True)
                if text:
                    await self._append_job_output(job, name, text)
                return
            text = decoder.decode(chunk)
            if text:
                await self._append_job_output(job, name, text)

    async def _append_job_output(self, job: CommandJob, name: str, text: str) -> None:
        async with job.condition:
            value = getattr(job, name) + text
            start_name = f"{name}_start"
            start = getattr(job, start_name)
            if len(value) > MAX_RESPONSE_CHARS:
                drop = len(value) - MAX_RESPONSE_CHARS
                value = value[drop:]
                start += drop
            setattr(job, name, value)
            setattr(job, start_name, start)
            job.condition.notify_all()

    async def _monitor_command_job(self, job: CommandJob) -> None:
        await job.proc.wait()
        await asyncio.gather(*job.tasks[:2], return_exceptions=True)
        job.exit_code = job.proc.returncode
        job.finished_at = time.monotonic()
        job.status = "cancelled" if job.cancel_requested else "exited"
        async with job.condition:
            job.condition.notify_all()

    def _get_command_job(self, job_id: Any) -> CommandJob:
        if not isinstance(job_id, str) or not job_id:
            raise AgentError("invalid_request", "job_id must be a non-empty string.")
        job = self.command_jobs.get(job_id)
        if job is None:
            raise AgentError("job_not_found", "Command job was not found.")
        return job

    @staticmethod
    def _job_offset(value: Any, name: str) -> int:
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise AgentError("invalid_request", f"{name} must be an integer >= 0.")
        return value

    @staticmethod
    def _job_has_new_output(job: CommandJob, stdout_offset: int, stderr_offset: int) -> bool:
        return (
            stdout_offset < job.stdout_start + len(job.stdout)
            or stderr_offset < job.stderr_start + len(job.stderr)
        )

    def _command_job_poll_result(
        self,
        job: CommandJob,
        stdout_offset: int,
        stderr_offset: int,
    ) -> dict[str, Any]:
        stdout_truncated = stdout_offset < job.stdout_start
        stderr_truncated = stderr_offset < job.stderr_start
        stdout_from = max(stdout_offset, job.stdout_start)
        stderr_from = max(stderr_offset, job.stderr_start)
        stdout_index = stdout_from - job.stdout_start
        stderr_index = stderr_from - job.stderr_start
        result = self._command_job_summary(job)
        result.update(
            {
                "stdout": job.stdout[stdout_index:],
                "stderr": job.stderr[stderr_index:],
                "stdout_offset": job.stdout_start + len(job.stdout),
                "stderr_offset": job.stderr_start + len(job.stderr),
                "truncated": stdout_truncated or stderr_truncated,
            }
        )
        return result

    @staticmethod
    def _command_job_summary(job: CommandJob) -> dict[str, Any]:
        end = job.finished_at if job.finished_at is not None else time.monotonic()
        return {
            "job_id": job.job_id,
            "command": job.command,
            "cwd": job.cwd,
            "status": job.status,
            "exit_code": job.exit_code,
            "duration_ms": int((end - job.started_at) * 1000),
        }

    def _prune_command_jobs(self) -> None:
        finished = sorted(
            (job for job in self.command_jobs.values() if job.status != "running"),
            key=lambda job: job.finished_at or job.started_at,
            reverse=True,
        )
        for job in finished[50:]:
            self.command_jobs.pop(job.job_id, None)


# ---------------------------------------------------------------------------
# WebSocket client
# ---------------------------------------------------------------------------


TOOL_ALIASES = {
    "exec": "execute_command",
    "execute_command": "execute_command",
    "start_command": "start_command",
    "poll_command": "poll_command",
    "cancel_command": "cancel_command",
    "list_commands": "list_commands",
    "read_file": "read_file",
    "write_file": "write_file",
    "delete_file": "delete_file",
    "move_file": "move_file",
    "stat_file": "stat_file",
    "search_files": "search_files",
    "apply_patch": "apply_patch",
    "list_files": "list_files",
}


class RemoteAgent:
    def __init__(
        self,
        server_url: str,
        workspace: Workspace,
        *,
        sandbox: bool,
        network: bool,
        copy_token: bool = False,
    ):
        self.server_url = server_url
        self.workspace = workspace
        self.identity = AgentIdentity.generate()
        self.tools = AgentTools(workspace, sandbox=sandbox, network=network)
        self.copy_token = copy_token
        # Serialized per-agent execution for V1.
        self.operation_lock = asyncio.Lock()

    def print_identity(self, *, replaced: bool = False) -> None:
        print()
        print(" ", colorize("My token is:", ANSI_BOLD, ANSI_CYAN), flush=True)
        print(" ", colorize(self.identity.token, ANSI_CYAN), flush=True)
        print()
        if self.copy_token:
            self.copy_identity_token()

    def copy_identity_token(self) -> None:
        if not sys.stdout.isatty():
            print("Token copy skipped: stdout is not a terminal.", file=sys.stderr, flush=True)
            return
        clipboard_text = f"My token is {self.identity.token}"
        encoded = base64.b64encode(clipboard_text.encode("utf-8")).decode("ascii")
        print(f"\033]52;c;{encoded}\a", end="", flush=True)
        print(colorize("Token copied.", ANSI_GREEN), flush=True)

    async def copy_key_loop(self) -> None:
        if os.name != "posix" or not sys.stdin.isatty() or not sys.stdout.isatty():
            return

        import termios
        import tty

        fd = sys.stdin.fileno()
        previous = termios.tcgetattr(fd)
        loop = asyncio.get_running_loop()
        keys: asyncio.Queue[bytes] = asyncio.Queue()

        def on_stdin() -> None:
            data = os.read(fd, 1)
            if data:
                keys.put_nowait(data)

        try:
            tty.setcbreak(fd)
            loop.add_reader(fd, on_stdin)
            print(colorize("Press C to copy the current token.", ANSI_YELLOW), flush=True)
            while True:
                key = await keys.get()
                if key.lower() == b"c":
                    self.copy_identity_token()
        finally:
            loop.remove_reader(fd)
            termios.tcsetattr(fd, termios.TCSADRAIN, previous)

    async def run_forever(self) -> None:
        delay = RECONNECT_MIN_DELAY
        while True:
            try:
                print(colorize(f"Connecting to {self.server_url} ...", ANSI_BLUE), flush=True)
                async with websockets.connect(
                    self.server_url,
                    ping_interval=20,
                    ping_timeout=20,
                    close_timeout=5,
                    max_size=2 * 1024 * 1024,
                ) as ws:
                    await self._send_hello(ws)
                    print(colorize("Connected.", ANSI_GREEN, ANSI_BOLD), flush=True)
                    delay = RECONNECT_MIN_DELAY
                    await self._connection_loop(ws)
            except asyncio.CancelledError:
                raise
            except KeyboardInterrupt:
                raise
            except Exception as exc:
                print(colorize(f"Disconnected: {exc}", ANSI_RED, stream=sys.stderr), file=sys.stderr, flush=True)

            print(colorize(f"Reconnecting in {delay:.0f}s ...", ANSI_YELLOW), flush=True)
            await asyncio.sleep(delay)
            delay = min(delay * 2, RECONNECT_MAX_DELAY)

    async def _send_hello(self, ws: Any) -> None:
        await ws.send(json.dumps({"type": "hello", "machine_id": self.identity.machine_id}))

    async def _connection_loop(self, ws: Any) -> None:
        poll_tasks: set[asyncio.Task[None]] = set()
        try:
            async for raw in ws:
                try:
                    message = json.loads(raw)
                except (json.JSONDecodeError, TypeError):
                    await ws.send(json.dumps({"type": "error", "code": "invalid_json"}))
                    continue

                if not isinstance(message, dict):
                    await ws.send(json.dumps({"type": "error", "code": "invalid_message"}))
                    continue

                # Registration collision: regenerate the entire temporary token and retry.
                if message.get("type") == "error" and message.get("code") == "machine_id_collision":
                    self.identity = AgentIdentity.generate()
                    self.print_identity(replaced=True)
                    await self._send_hello(ws)
                    continue

                # Long polls must not block later cancel/list requests arriving on
                # the same WebSocket connection.
                if TOOL_ALIASES.get(str(message.get("type"))) == "poll_command":
                    task = asyncio.create_task(self._handle_message(ws, message))
                    poll_tasks.add(task)
                    task.add_done_callback(poll_tasks.discard)
                    continue

                await self._handle_message(ws, message)
        finally:
            for task in poll_tasks:
                task.cancel()
            if poll_tasks:
                await asyncio.gather(*poll_tasks, return_exceptions=True)

    async def _handle_message(self, ws: Any, message: dict[str, Any]) -> None:
        op_type = message.get("type")
        request_id = message.get("request_id")
        canonical = TOOL_ALIASES.get(str(op_type))

        if canonical is None:
            # Ignore unrelated server control messages, but respond to operation-like
            # requests that carry a request_id.
            if request_id is not None:
                await self._send_error(ws, request_id, "unsupported_operation", f"Unsupported operation: {op_type}")
            return

        if not isinstance(request_id, str) or not request_id:
            await ws.send(json.dumps({"type": "error", "code": "missing_request_id"}))
            return

        if canonical in {"poll_command", "cancel_command", "list_commands"}:
            await self._run_operation(ws, message, canonical, request_id)
        else:
            async with self.operation_lock:
                await self._run_operation(ws, message, canonical, request_id)

    async def _run_operation(
        self,
        ws: Any,
        message: dict[str, Any],
        canonical: str,
        request_id: str,
    ) -> None:
        started = time.monotonic()
        detail = operation_detail(canonical, message)
        try:
            token = message.get("token")
            if not isinstance(token, str) or not self.identity.matches(token):
                raise AgentError("invalid_token", "Invalid agent token.")

            handler = getattr(self.tools, canonical)
            result = await handler(message)
            response = {"type": "result", "request_id": request_id, "result": result}
            elapsed = time.monotonic() - started
            line = colorize("DONE", ANSI_GREEN, ANSI_BOLD)
            line += " " + colorize(canonical, ANSI_CYAN, ANSI_BOLD)
            if detail:
                line += " " + colorize(detail, ANSI_YELLOW)
            line += colorize(f" ({elapsed:.2f}s)", ANSI_GREEN)
            print(line, flush=True)
        except AgentError as exc:
            response = {"type": "result", "request_id": request_id, "error": exc.to_dict()}
            elapsed = time.monotonic() - started
            line = colorize("FAIL", ANSI_RED, ANSI_BOLD)
            line += " " + colorize(canonical, ANSI_CYAN, ANSI_BOLD)
            if detail:
                line += " " + colorize(detail, ANSI_YELLOW)
            line += colorize(f" [{exc.code}] ({elapsed:.2f}s)", ANSI_RED)
            print(line, file=sys.stderr, flush=True)
        except Exception:
            response = {
                "type": "result",
                "request_id": request_id,
                "error": {"code": "internal_error", "message": "Unhandled agent error."},
            }
            elapsed = time.monotonic() - started
            line = colorize("FAIL", ANSI_RED, ANSI_BOLD)
            line += " " + colorize(canonical, ANSI_CYAN, ANSI_BOLD)
            if detail:
                line += " " + colorize(detail, ANSI_YELLOW)
            line += colorize(f" [internal_error] ({elapsed:.2f}s)", ANSI_RED)
            print(line, file=sys.stderr, flush=True)
        await ws.send(json.dumps(response, ensure_ascii=False))

    async def _send_error(self, ws: Any, request_id: Any, code: str, message: str) -> None:
        await ws.send(
            json.dumps(
                {
                    "type": "result",
                    "request_id": request_id,
                    "error": {"code": code, "message": message},
                }
            )
        )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Remote coding agent")
    parser.add_argument(
        "--server",
        default=DEFAULT_SERVER,
        help=f"WebSocket server URL (default: {DEFAULT_SERVER!r}; env: REMOTE_AGENT_SERVER)",
    )
    parser.add_argument(
        "--network",
        action="store_true",
        help="Allow network access inside the command sandbox.",
    )
    parser.add_argument(
        "--no-sandbox",
        action="store_true",
        help="Disable command sandboxing (DANGEROUS).",
    )
    parser.add_argument(
        "--copy-token",
        action="store_true",
        help="Copy each generated machine token via terminal clipboard (OSC 52).",
    )
    return parser.parse_args()


def validate_startup(args: argparse.Namespace, workspace: Workspace) -> None:
    if os.name != "posix":
        if not args.no_sandbox:
            raise SystemExit("Sandboxed command execution currently requires Linux or macOS. Use --no-sandbox only if you accept unrestricted execution.")

    if not args.no_sandbox:
        if sys.platform == "darwin":
            if shutil.which("sandbox-exec") is None:
                raise SystemExit(
                    "Sandbox unavailable: 'sandbox-exec' was not found on this macOS system.\n"
                    "Use --no-sandbox only if you accept unrestricted execution."
                )
        elif shutil.which("bwrap") is None:
            raise SystemExit(
                "Sandbox unavailable: 'bwrap' was not found.\n"
                "Install the bubblewrap package, or explicitly use --no-sandbox (unsafe)."
            )

    if args.network and args.no_sandbox:
        print("Note: --network has no effect when --no-sandbox is used.", file=sys.stderr)

    print(f"Project root: {workspace.root}")
    if args.no_sandbox:
        sandbox_status = "disabled (UNSAFE)"
    elif sys.platform == "darwin":
        sandbox_status = "enabled (macOS sandbox-exec)"
    else:
        sandbox_status = "enabled (bubblewrap)"
    print(f"Filesystem sandbox: {sandbox_status}")
    print(f"Network access: {'enabled' if args.network or args.no_sandbox else 'disabled'}")

    if args.no_sandbox:
        print(
            "WARNING: --no-sandbox allows remote commands to access the host with the current user's permissions.",
            file=sys.stderr,
        )


async def async_main() -> None:
    args = parse_args()
    workspace = Workspace(Path.cwd())
    validate_startup(args, workspace)

    agent = RemoteAgent(
        args.server,
        workspace,
        sandbox=not args.no_sandbox,
        network=args.network,
        copy_token=args.copy_token,
    )
    agent.print_identity()
    copy_task = asyncio.create_task(agent.copy_key_loop())
    try:
        await agent.run_forever()
    finally:
        copy_task.cancel()
        await agent.tools.shutdown_command_jobs()
        await asyncio.gather(copy_task, return_exceptions=True)


def main() -> None:
    try:
        asyncio.run(async_main())
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
__CODER_AGENT_PY_EOF_7C9B5F2A__
}

make_payload() {
    tmp_dir=${TMPDIR:-/tmp}
    if command -v mktemp >/dev/null 2>&1; then
        payload=$(mktemp "$tmp_dir/coder-agent.XXXXXX" 2>/dev/null || true)
    else
        payload=
    fi

    if [ -z "${payload:-}" ]; then
        # Portable fallback for older/minimal Unix systems where mktemp is
        # missing or uses incompatible flags. noclobber avoids overwriting an
        # existing file if the predictable candidate happens to exist.
        old_umask=$(umask)
        umask 077
        i=0
        while [ "$i" -lt 100 ]; do
            candidate="$tmp_dir/coder-agent.$$.${i}"
            if (set -C; : >"$candidate") 2>/dev/null; then
                payload=$candidate
                break
            fi
            i=$((i + 1))
        done
        umask "$old_umask"
    fi

    if [ -z "${payload:-}" ]; then
        say "Could not create a temporary file." >&2
        exit 1
    fi

    trap 'rm -f "$payload"' EXIT HUP INT TERM
    write_agent >"$payload"
    chmod 755 "$payload"
}

install_file() {
    src=$1
    dest=$2
    dest_dir=$(dirname "$dest")
    mkdir -p "$dest_dir"
    cp "$src" "$dest"
    chmod 755 "$dest"
}

install_local() {
    if [ -n "${LOCAL_TARGET:-}" ]; then
        if ask_yes_no "Install for this user to $LOCAL_TARGET?" yes; then
            install_file "$payload" "$LOCAL_TARGET"
            finish_install "$LOCAL_TARGET"
            case ":${PATH:-}:" in
                *":$HOME/.local/bin:"*) ;;
                *) say "Note: add $HOME/.local/bin to PATH to run 'coder' directly." ;;
            esac
            return 0
        else
            answer_status=$?
            if [ "$answer_status" -eq 2 ]; then
                # No controlling terminal (common in automation): prefer the
                # conventional per-user location without blocking.
                install_file "$payload" "$LOCAL_TARGET"
                finish_install "$LOCAL_TARGET"
                case ":${PATH:-}:" in
                    *":$HOME/.local/bin:"*) ;;
                    *) say "Note: add $HOME/.local/bin to PATH to run 'coder' directly." ;;
                esac
                return 0
            fi
        fi
    fi

    install_file "$payload" "$CURRENT_TARGET"
    finish_install "$CURRENT_TARGET"
}

make_payload

if [ "$(id -u)" -eq 0 ]; then
    install_file "$payload" "$SYSTEM_TARGET"
    finish_install "$SYSTEM_TARGET"
    exit 0
fi

if [ -d "$(dirname "$SYSTEM_TARGET")" ] && [ -w "$(dirname "$SYSTEM_TARGET")" ]; then
    install_file "$payload" "$SYSTEM_TARGET"
    finish_install "$SYSTEM_TARGET"
    exit 0
fi

if command -v sudo >/dev/null 2>&1; then
    if ask_yes_no "Install system-wide to $SYSTEM_TARGET using sudo?" yes; then
        system_dir=$(dirname "$SYSTEM_TARGET")
        if sudo mkdir -p "$system_dir" \
            && sudo cp "$payload" "$SYSTEM_TARGET" \
            && sudo chmod 755 "$SYSTEM_TARGET"; then
            finish_install "$SYSTEM_TARGET"
            exit 0
        fi
        say "System-wide installation failed; offering a local installation instead." >&2
    else
        answer_status=$?
        if [ "$answer_status" -eq 2 ]; then
            say "No interactive terminal available; installing without sudo."
        else
            say "System-wide installation declined."
        fi
    fi
else
    say "sudo is not available; offering a local installation instead."
fi

install_local
