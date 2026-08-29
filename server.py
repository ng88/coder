#!/usr/bin/env python3
"""Public bridge server for the lightweight remote coding agent.

The server exposes:

- WebSocket: /ws/agent
- GPT/HTTP tools:
    POST /api/exec
    POST /api/read-file
    POST /api/search-files
    POST /api/apply-patch
    POST /api/list-files
- FastAPI OpenAPI schema: /openapi.json
- Health endpoint: /health

Agents connect outbound over WebSocket and register a public machine_id. GPT tool
requests contain a token of the form machineid:authid. The server uses machineid
for routing and forwards the complete token to the agent, which performs the
actual authentication.

Python dependencies:
    python -m pip install fastapi uvicorn

Typical development start:
    python server.py

Production is normally run behind an HTTPS reverse proxy such as Caddy or nginx:
    python server.py --host 127.0.0.1 --port 8000

The reverse proxy should expose HTTPS/WSS publicly and proxy WebSocket upgrades.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import re
import secrets
import sys
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Literal

try:
    import uvicorn
    from fastapi import FastAPI, WebSocket, WebSocketDisconnect
    from fastapi.responses import JSONResponse
    from pydantic import BaseModel, Field
except ImportError as exc:  # pragma: no cover - startup dependency check
    print(
        "Missing Python dependencies.\n"
        "Install them with: python -m pip install fastapi uvicorn",
        file=sys.stderr,
    )
    raise SystemExit(2) from exc


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DEFAULT_HOST = os.environ.get("REMOTE_AGENT_HOST", "127.0.0.1")
DEFAULT_PORT = int(os.environ.get("REMOTE_AGENT_PORT", "8000"))

# Agent currently uses websockets max_size=2 MiB. Keep the server at the same
# order of magnitude so a request that fits one side also fits the other.
MAX_WS_MESSAGE_BYTES = 2 * 1024 * 1024

# HTTP -> WS bridge timeout for non-command operations. Commands use their own
# requested timeout plus a grace period. timeout=0 intentionally waits without
# a server-side execution deadline (upstream HTTP infrastructure may still time out).
DEFAULT_TOOL_BRIDGE_TIMEOUT = 60.0
COMMAND_TIMEOUT_GRACE = 15.0

MAX_COMMAND_CHARS = 500_000
MAX_PATCH_CHARS = 400_000
MAX_PATH_CHARS = 4096
MAX_QUERY_CHARS = 20_000
MAX_GLOB_CHARS = 4096

MACHINE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,128}$")
AUTH_ID_RE = re.compile(r"^[A-Za-z0-9_-]{16,512}$")

logger = logging.getLogger("remote-agent-server")


# ---------------------------------------------------------------------------
# Models exposed through OpenAPI / GPT Actions
# ---------------------------------------------------------------------------


class TokenRequest(BaseModel):
    token: str = Field(
        ...,
        min_length=25,
        max_length=700,
        description=(
            "Complete temporary agent token supplied by the user, in the form "
            "machineid:authid. The machine ID is used for routing and authid is "
            "validated by the target agent."
        ),
    )


class ExecuteCommandRequest(TokenRequest):
    command: str = Field(
        ...,
        min_length=1,
        max_length=MAX_COMMAND_CHARS,
        description="Bash command to execute on the connected agent.",
    )
    timeout: int = Field(
        default=30,
        ge=0,
        description="Maximum execution time in seconds. 0 means no agent-side timeout.",
    )
    cwd: str | None = Field(
        default=None,
        max_length=MAX_PATH_CHARS,
        description=(
            "Working directory relative to the agent project root. If omitted, "
            "the project root is used. Absolute host paths are not allowed."
        ),
    )


class StartCommandRequest(TokenRequest):
    command: str = Field(..., min_length=1, max_length=MAX_COMMAND_CHARS)
    cwd: str | None = Field(default=None, max_length=MAX_PATH_CHARS)


class PollCommandRequest(TokenRequest):
    job_id: str = Field(..., min_length=1, max_length=200)
    stdout_offset: int = Field(default=0, ge=0)
    stderr_offset: int = Field(default=0, ge=0)
    wait_seconds: int = Field(default=0, ge=0, le=30)


class CommandJobRequest(TokenRequest):
    job_id: str = Field(..., min_length=1, max_length=200)


class ListCommandsRequest(TokenRequest):
    pass


class ReadFileRequest(TokenRequest):
    path: str = Field(
        ...,
        min_length=1,
        max_length=MAX_PATH_CHARS,
        description="File path relative to the agent project root.",
    )
    start_line: int | None = Field(default=None, ge=1, description="First line to return, 1-based.")
    end_line: int | None = Field(default=None, ge=1, description="Last line to return, inclusive and 1-based.")


class WriteFileRequest(TokenRequest):
    path: str = Field(..., min_length=1, max_length=MAX_PATH_CHARS)
    content: str
    overwrite: bool = False
    create_parents: bool = False


class DeleteFileRequest(TokenRequest):
    path: str = Field(..., min_length=1, max_length=MAX_PATH_CHARS)


class MoveFileRequest(TokenRequest):
    source: str = Field(..., min_length=1, max_length=MAX_PATH_CHARS)
    destination: str = Field(..., min_length=1, max_length=MAX_PATH_CHARS)
    overwrite: bool = False
    create_parents: bool = False


class StatFileRequest(TokenRequest):
    path: str = Field(..., min_length=1, max_length=MAX_PATH_CHARS)


class SearchFilesRequest(TokenRequest):
    query: str = Field(..., min_length=1, max_length=MAX_QUERY_CHARS, description="Literal text to search for.")
    path: str | None = Field(
        default=None,
        max_length=MAX_PATH_CHARS,
        description="File or directory path relative to the project root. Defaults to the project root.",
    )
    glob: str | None = Field(
        default=None,
        max_length=MAX_GLOB_CHARS,
        description="Optional glob filter such as '*.py' or 'src/*.ts'.",
    )
    max_results: int | None = Field(default=None, ge=1, le=100, description="Maximum number of matches to return.")


class ApplyPatchRequest(TokenRequest):
    patch: str = Field(
        ...,
        min_length=1,
        max_length=MAX_PATCH_CHARS,
        description=(
            "Unified diff to apply inside the project. Prefer this tool for localized "
            "source-code edits rather than shell-based file rewriting."
        ),
    )


class ListFilesRequest(TokenRequest):
    path: str | None = Field(
        default=None,
        max_length=MAX_PATH_CHARS,
        description="File or directory path relative to the project root. Defaults to '.'.",
    )
    depth: int | None = Field(default=None, ge=0, le=20, description="Maximum directory traversal depth. Defaults to 2.")
    max_entries: int | None = Field(default=None, ge=1, le=500, description="Maximum number of entries to return.")


class CommandResult(BaseModel):
    stdout: str
    stderr: str
    exit_code: int | None
    timed_out: bool
    truncated: bool = False
    duration_ms: int | None = None


class CommandJobSummary(BaseModel):
    job_id: str
    command: str
    cwd: str
    status: str
    exit_code: int | None
    duration_ms: int


class StartCommandResult(BaseModel):
    job_id: str
    status: str
    command: str
    cwd: str


class PollCommandResult(CommandJobSummary):
    stdout: str
    stderr: str
    stdout_offset: int
    stderr_offset: int
    truncated: bool


class ListCommandsResult(BaseModel):
    jobs: list[CommandJobSummary]


class ReadFileResult(BaseModel):
    path: str
    start_line: int
    end_line: int
    total_lines: int
    content: str
    truncated: bool


class WriteFileResult(BaseModel):
    path: str
    bytes: int
    sha256: str


class DeleteFileResult(BaseModel):
    path: str
    deleted: bool


class MoveFileResult(BaseModel):
    source: str
    destination: str
    bytes: int
    sha256: str


class StatFileResult(BaseModel):
    path: str
    type: str
    size: int
    mtime_ns: int
    sha256: str | None


class SearchMatch(BaseModel):
    path: str
    line: int
    text: str


class SearchFilesResult(BaseModel):
    matches: list[SearchMatch]
    truncated: bool


class ApplyPatchResult(BaseModel):
    applied: bool
    files_changed: list[str]


class ListEntry(BaseModel):
    path: str
    type: Literal["file", "directory", "symlink"] | str


class ListFilesResult(BaseModel):
    entries: list[ListEntry]
    truncated: bool


class ErrorBody(BaseModel):
    code: str
    message: str
    details: dict[str, Any] | None = None


class ErrorEnvelope(BaseModel):
    error: ErrorBody


ERROR_RESPONSES = {
    400: {"model": ErrorEnvelope, "description": "Invalid request or path."},
    401: {"model": ErrorEnvelope, "description": "The agent rejected the token."},
    404: {"model": ErrorEnvelope, "description": "Target machine or file not found."},
    409: {"model": ErrorEnvelope, "description": "Patch conflict or state conflict."},
    503: {"model": ErrorEnvelope, "description": "Agent disconnected or unavailable."},
    504: {"model": ErrorEnvelope, "description": "The server stopped waiting for the agent response."},
}


# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------


def parse_token(token: str) -> tuple[str, str]:
    """Validate the routing-level token format and return machine_id/auth_id.

    Authentication itself is intentionally not performed here; the complete
    token is forwarded to the agent for constant-time validation.
    """

    if not isinstance(token, str) or ":" not in token:
        raise ValueError("Malformed agent token.")
    machine_id, auth_id = token.split(":", 1)
    if not MACHINE_ID_RE.fullmatch(machine_id) or not AUTH_ID_RE.fullmatch(auth_id):
        raise ValueError("Malformed agent token.")
    return machine_id, auth_id


def error_payload(code: str, message: str, *, details: dict[str, Any] | None = None) -> dict[str, Any]:
    body: dict[str, Any] = {"code": code, "message": message}
    if details:
        body["details"] = details
    return {"error": body}


def status_for_agent_error(code: str) -> int:
    if code == "invalid_token":
        return 401
    if code in {"file_not_found", "machine_not_connected", "job_not_found"}:
        return 404
    if code in {"patch_conflict", "already_exists", "too_many_jobs"}:
        return 409
    if code in {
        "invalid_request",
        "invalid_path",
        "path_outside_workspace",
        "invalid_patch",
        "binary_file",
        "file_too_large",
        "unsupported_operation",
    }:
        return 400
    if code in {"sandbox_unavailable", "execution_failed"}:
        return 503
    return 500


# ---------------------------------------------------------------------------
# WebSocket registry / pending HTTP bridge
# ---------------------------------------------------------------------------


class AgentDisconnected(Exception):
    pass


@dataclass
class AgentConnection:
    machine_id: str
    websocket: WebSocket
    connected_at: float = field(default_factory=time.monotonic)
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    async def send_json(self, payload: dict[str, Any]) -> None:
        # Starlette WebSocket sends should be serialized when multiple HTTP calls
        # target the same agent concurrently.
        async with self.send_lock:
            await self.websocket.send_text(json.dumps(payload, ensure_ascii=False))


@dataclass
class PendingRequest:
    request_id: str
    machine_id: str
    operation: str
    future: asyncio.Future[dict[str, Any]]
    started_at: float = field(default_factory=time.monotonic)


class ServerState:
    def __init__(self) -> None:
        self.agents: dict[str, AgentConnection] = {}
        self.pending: dict[str, PendingRequest] = {}

    async def register(self, machine_id: str, websocket: WebSocket) -> AgentConnection | None:
        if not MACHINE_ID_RE.fullmatch(machine_id):
            await websocket.send_json({"type": "error", "code": "invalid_machine_id"})
            return None
        if machine_id in self.agents:
            await websocket.send_json({"type": "error", "code": "machine_id_collision"})
            return None

        conn = AgentConnection(machine_id=machine_id, websocket=websocket)
        self.agents[machine_id] = conn
        peer = None
        if websocket.client is not None:
            peer = f"{websocket.client.host}:{websocket.client.port}"
        logger.info("Agent connected: %s%s", machine_id, f" from {peer}" if peer else "")
        return conn

    async def unregister(self, conn: AgentConnection, *, reason: str = "disconnected") -> None:
        # A replacement connection must never be removed by a stale handler.
        if self.agents.get(conn.machine_id) is conn:
            self.agents.pop(conn.machine_id, None)

        for request_id, pending in list(self.pending.items()):
            if pending.machine_id != conn.machine_id:
                continue
            self.pending.pop(request_id, None)
            if not pending.future.done():
                pending.future.set_exception(AgentDisconnected("Agent disconnected before responding."))

        logger.info("Agent disconnected: %s (%s)", conn.machine_id, reason)

    async def handle_agent_message(self, conn: AgentConnection, message: Any) -> None:
        if not isinstance(message, dict):
            await conn.send_json({"type": "error", "code": "invalid_message"})
            return

        if message.get("type") != "result":
            # The current agent protocol only sends results after registration.
            logger.warning("Unexpected message from %s: %r", conn.machine_id, message.get("type"))
            return

        request_id = message.get("request_id")
        if not isinstance(request_id, str) or not request_id:
            await conn.send_json({"type": "error", "code": "missing_request_id"})
            return

        pending = self.pending.get(request_id)
        if pending is None:
            # Usually a late response after the HTTP bridge timed out/cancelled.
            logger.warning("Orphan response from %s for request %s", conn.machine_id, request_id)
            return

        # Prevent one connected agent from completing another agent's pending request
        # even if a request ID somehow leaks or collides.
        if pending.machine_id != conn.machine_id:
            logger.warning(
                "Cross-machine response rejected: got %s, expected %s, request=%s",
                conn.machine_id,
                pending.machine_id,
                request_id,
            )
            return

        self.pending.pop(request_id, None)
        if not pending.future.done():
            pending.future.set_result(message)

    async def route_operation(
        self,
        operation: str,
        payload: dict[str, Any],
        *,
        bridge_timeout: float | None,
    ) -> tuple[int, dict[str, Any]]:
        token = payload.get("token")
        try:
            machine_id, _ = parse_token(token)
        except (TypeError, ValueError):
            return 400, error_payload("invalid_token_format", "Malformed agent token.")

        conn = self.agents.get(machine_id)
        if conn is None:
            return 404, error_payload(
                "machine_not_connected",
                "The agent associated with this token is not connected.",
            )

        request_id = str(uuid.uuid4())
        ws_message = {"type": operation, "request_id": request_id, **payload}
        loop = asyncio.get_running_loop()
        future: asyncio.Future[dict[str, Any]] = loop.create_future()
        pending = PendingRequest(
            request_id=request_id,
            machine_id=machine_id,
            operation=operation,
            future=future,
        )
        self.pending[request_id] = pending

        try:
            await conn.send_json(ws_message)
        except Exception as exc:
            self.pending.pop(request_id, None)
            if not future.done():
                future.cancel()
            response = error_payload("machine_not_connected", "Unable to send request to the agent.")
            return 503, response

        try:
            if bridge_timeout is None:
                agent_message = await future
            else:
                agent_message = await asyncio.wait_for(future, timeout=bridge_timeout)
        except AgentDisconnected:
            response = error_payload("machine_not_connected", "Agent disconnected before responding.")
            return 503, response
        except asyncio.TimeoutError:
            self.pending.pop(request_id, None)
            if not future.done():
                future.cancel()
            response = error_payload("bridge_timeout", "Timed out waiting for the agent response.")
            return 504, response
        except asyncio.CancelledError:
            # HTTP client went away / server is shutting down. Remove the pending
            # mapping; a later agent response will be recorded as orphan_response.
            self.pending.pop(request_id, None)
            if not future.done():
                future.cancel()
            raise

        if "error" in agent_message:
            err = agent_message.get("error") or {}
            code = str(err.get("code", "agent_error")) if isinstance(err, dict) else "agent_error"
            status = status_for_agent_error(code)
            return status, {"error": err if isinstance(err, dict) else {"code": code, "message": str(err)}}

        result = agent_message.get("result")
        if not isinstance(result, dict):
            return 500, error_payload("invalid_agent_response", "Agent returned an invalid response.")
        return 200, result


state = ServerState()


# ---------------------------------------------------------------------------
# FastAPI application
# ---------------------------------------------------------------------------


app = FastAPI(
    title="Remote Coding Agent API",
    version="1.0.0",
    servers=[
        {"url": "https://coder.nghs.fr"},
    ],
    description=(
        "Routes Custom GPT coding tools to a connected local agent. "
        "The user must supply the temporary machine token printed by "
        "the agent. The token already contains the machine identifier; "
        "never request a separate machine name or ID."
    ),
)


@app.get("/health", include_in_schema=False)
async def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "connected_agents": len(state.agents),
        "pending_requests": len(state.pending),
    }


@app.websocket("/ws/agent")
async def agent_websocket(websocket: WebSocket) -> None:
    await websocket.accept()
    conn: AgentConnection | None = None
    close_reason = "disconnected"

    try:
        # Registration may repeat on the same socket after a machine_id collision;
        # the current agent regenerates its full token and sends another hello.
        while conn is None:
            try:
                raw = await asyncio.wait_for(websocket.receive_text(), timeout=30.0)
            except asyncio.TimeoutError:
                close_reason = "registration_timeout"
                await websocket.close(code=1008, reason="hello timeout")
                return

            try:
                hello = json.loads(raw)
            except json.JSONDecodeError:
                await websocket.send_json({"type": "error", "code": "invalid_json"})
                continue

            if not isinstance(hello, dict) or hello.get("type") != "hello":
                await websocket.send_json({"type": "error", "code": "hello_required"})
                continue

            machine_id = hello.get("machine_id")
            if not isinstance(machine_id, str):
                await websocket.send_json({"type": "error", "code": "invalid_machine_id"})
                continue

            conn = await state.register(machine_id, websocket)

        while True:
            raw = await websocket.receive_text()
            try:
                message = json.loads(raw)
            except json.JSONDecodeError:
                await conn.send_json({"type": "error", "code": "invalid_json"})
                continue
            await state.handle_agent_message(conn, message)

    except WebSocketDisconnect as exc:
        close_reason = f"websocket_disconnect:{exc.code}"
    except asyncio.CancelledError:
        close_reason = "server_shutdown"
        raise
    except Exception as exc:
        close_reason = f"error:{type(exc).__name__}"
        logger.exception("WebSocket handler failed%s", f" for {conn.machine_id}" if conn else "")
    finally:
        if conn is not None:
            await state.unregister(conn, reason=close_reason)


def _public_payload(model: BaseModel) -> dict[str, Any]:
    # exclude_none keeps optional absent parameters truly absent so the agent's own
    # defaults are used. This matters for read_file line ranges and list/search limits.
    return model.model_dump(exclude_none=True)


async def _run_tool(operation: str, model: BaseModel, *, timeout: float | None) -> JSONResponse | dict[str, Any]:
    status, body = await state.route_operation(operation, _public_payload(model), bridge_timeout=timeout)
    if status == 200:
        return body
    return JSONResponse(status_code=status, content=body)


@app.post(
    "/api/exec",
    operation_id="executeCommand",
    summary="Execute a Bash command on the connected machine",
    description=(
        "Execute a Bash command on the agent identified by the machine ID embedded "
        "in `token`. `cwd` is relative to the project root. `timeout=0` means no "
        "agent-side timeout. Prefer structured file tools for file operations; use "
        "this for tests, builds, Git, and arbitrary commands."
    ),
    response_model=CommandResult,
    responses=ERROR_RESPONSES,
)
async def execute_command(request: ExecuteCommandRequest) -> JSONResponse | dict[str, Any]:
    bridge_timeout = None if request.timeout == 0 else float(request.timeout) + COMMAND_TIMEOUT_GRACE
    return await _run_tool("execute_command", request, timeout=bridge_timeout)


@app.post(
    "/api/start-command",
    operation_id="startCommand",
    summary="Start a long-running Bash command",
    response_model=StartCommandResult,
    responses=ERROR_RESPONSES,
)
async def start_command(request: StartCommandRequest) -> JSONResponse | dict[str, Any]:
    return await _run_tool("start_command", request, timeout=DEFAULT_TOOL_BRIDGE_TIMEOUT)


@app.post(
    "/api/poll-command",
    operation_id="pollCommand",
    summary="Poll a long-running command and read new output",
    response_model=PollCommandResult,
    responses=ERROR_RESPONSES,
)
async def poll_command(request: PollCommandRequest) -> JSONResponse | dict[str, Any]:
    return await _run_tool(
        "poll_command",
        request,
        timeout=float(request.wait_seconds) + DEFAULT_TOOL_BRIDGE_TIMEOUT,
    )


@app.post(
    "/api/cancel-command",
    operation_id="cancelCommand",
    summary="Cancel a long-running command",
    response_model=CommandJobSummary,
    responses=ERROR_RESPONSES,
)
async def cancel_command(request: CommandJobRequest) -> JSONResponse | dict[str, Any]:
    return await _run_tool("cancel_command", request, timeout=DEFAULT_TOOL_BRIDGE_TIMEOUT)


@app.post(
    "/api/list-commands",
    operation_id="listCommands",
    summary="List recent and running command jobs",
    response_model=ListCommandsResult,
    responses=ERROR_RESPONSES,
)
async def list_commands(request: ListCommandsRequest) -> JSONResponse | dict[str, Any]:
    return await _run_tool("list_commands", request, timeout=DEFAULT_TOOL_BRIDGE_TIMEOUT)


@app.post(
    "/api/read-file",
    operation_id="readFile",
    summary="Read a project file or line range",
    description=(
        "Read text from a file inside the project workspace. Paths are relative to "
        "the project root. Prefer targeted line ranges for large files."
    ),
    response_model=ReadFileResult,
    responses=ERROR_RESPONSES,
)
async def read_file(request: ReadFileRequest) -> JSONResponse | dict[str, Any]:
    if request.start_line is not None and request.end_line is not None and request.end_line < request.start_line:
        return JSONResponse(
            status_code=400,
            content=error_payload("invalid_request", "end_line must be >= start_line."),
        )
    return await _run_tool("read_file", request, timeout=DEFAULT_TOOL_BRIDGE_TIMEOUT)


@app.post("/api/write-file", operation_id="writeFile", response_model=WriteFileResult, responses=ERROR_RESPONSES)
async def write_file(request: WriteFileRequest) -> JSONResponse | dict[str, Any]:
    return await _run_tool("write_file", request, timeout=DEFAULT_TOOL_BRIDGE_TIMEOUT)


@app.post("/api/delete-file", operation_id="deleteFile", response_model=DeleteFileResult, responses=ERROR_RESPONSES)
async def delete_file(request: DeleteFileRequest) -> JSONResponse | dict[str, Any]:
    return await _run_tool("delete_file", request, timeout=DEFAULT_TOOL_BRIDGE_TIMEOUT)


@app.post("/api/move-file", operation_id="moveFile", response_model=MoveFileResult, responses=ERROR_RESPONSES)
async def move_file(request: MoveFileRequest) -> JSONResponse | dict[str, Any]:
    return await _run_tool("move_file", request, timeout=DEFAULT_TOOL_BRIDGE_TIMEOUT)


@app.post("/api/stat-file", operation_id="statFile", response_model=StatFileResult, responses=ERROR_RESPONSES)
async def stat_file(request: StatFileRequest) -> JSONResponse | dict[str, Any]:
    return await _run_tool("stat_file", request, timeout=DEFAULT_TOOL_BRIDGE_TIMEOUT)


@app.post(
    "/api/search-files",
    operation_id="searchFiles",
    summary="Search literal text in project files",
    description=(
        "Search project files for literal text and return structured path/line matches. "
        "Use `path` and `glob` to narrow searches when possible."
    ),
    response_model=SearchFilesResult,
    responses=ERROR_RESPONSES,
)
async def search_files(request: SearchFilesRequest) -> JSONResponse | dict[str, Any]:
    return await _run_tool("search_files", request, timeout=DEFAULT_TOOL_BRIDGE_TIMEOUT)


@app.post(
    "/api/apply-patch",
    operation_id="applyPatch",
    summary="Apply a unified diff to project files",
    description=(
        "Apply a localized unified diff inside the project workspace. This is the "
        "preferred tool for editing existing source code. Read the relevant code "
        "before patching, then inspect the diff and run appropriate tests afterward."
    ),
    response_model=ApplyPatchResult,
    responses=ERROR_RESPONSES,
)
async def apply_patch(request: ApplyPatchRequest) -> JSONResponse | dict[str, Any]:
    return await _run_tool("apply_patch", request, timeout=DEFAULT_TOOL_BRIDGE_TIMEOUT)


@app.post(
    "/api/list-files",
    operation_id="listFiles",
    summary="List files and directories in the project",
    description=(
        "Inspect project structure without shelling out to find. Paths are relative "
        "to the project root and results may be truncated at the requested limit."
    ),
    response_model=ListFilesResult,
    responses=ERROR_RESPONSES,
)
async def list_files(request: ListFilesRequest) -> JSONResponse | dict[str, Any]:
    return await _run_tool("list_files", request, timeout=DEFAULT_TOOL_BRIDGE_TIMEOUT)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Remote coding agent public server")
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"Bind host (default: {DEFAULT_HOST})")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"Bind port (default: {DEFAULT_PORT})")
    parser.add_argument(
        "--log-level",
        default=os.environ.get("REMOTE_AGENT_LOG_LEVEL", "info"),
        choices=["critical", "error", "warning", "info", "debug"],
        help="Console/Uvicorn log level (default: info).",
    )
    parser.add_argument(
        "--ssl-certfile",
        default=None,
        help="Optional TLS certificate file. Usually TLS is terminated by a reverse proxy instead.",
    )
    parser.add_argument(
        "--ssl-keyfile",
        default=None,
        help="Optional TLS private-key file. Usually TLS is terminated by a reverse proxy instead.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper()),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    if bool(args.ssl_certfile) != bool(args.ssl_keyfile):
        raise SystemExit("--ssl-certfile and --ssl-keyfile must be provided together.")

    logger.info("OpenAPI schema: /openapi.json")
    logger.info("Agent WebSocket: /ws/agent")

    uvicorn.run(
        app,
        host=args.host,
        port=args.port,
        log_level=args.log_level,
        ws_max_size=MAX_WS_MESSAGE_BYTES,
        ssl_certfile=args.ssl_certfile,
        ssl_keyfile=args.ssl_keyfile,
    )


if __name__ == "__main__":
    main()
