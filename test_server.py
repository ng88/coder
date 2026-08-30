import asyncio
from types import SimpleNamespace

import pytest
from pydantic import ValidationError

import server
from server import HttpRateLimitMiddleware, MAX_WRITE_CONTENT_CHARS, PendingRequest, RequestBodyLimitMiddleware, ServerState, WriteFileRequest, agent_websocket


def run_asgi(middleware, scope, incoming):
    sent = []
    messages = iter(incoming)

    async def receive():
        return next(messages)

    async def send(message):
        sent.append(message)

    asyncio.run(middleware(scope, receive, send))
    return sent


def http_scope(headers=None, *, path="/test", client=("203.0.113.10", 12345)):
    return {
        "type": "http",
        "method": "POST",
        "path": path,
        "headers": headers or [],
        "client": client,
    }


def test_request_body_limit_rejects_oversized_content_length_before_app_runs():
    called = False

    async def app(scope, receive, send):
        nonlocal called
        called = True

    middleware = RequestBodyLimitMiddleware(app, max_bytes=10)
    sent = run_asgi(
        middleware,
        http_scope([(b"content-length", b"11")]),
        [],
    )

    assert called is False
    assert sent[0]["status"] == 413


def test_request_body_limit_rejects_oversized_streamed_body():
    called = False

    async def app(scope, receive, send):
        nonlocal called
        called = True

    middleware = RequestBodyLimitMiddleware(app, max_bytes=10)
    sent = run_asgi(
        middleware,
        http_scope(),
        [
            {"type": "http.request", "body": b"123456", "more_body": True},
            {"type": "http.request", "body": b"78901", "more_body": False},
        ],
    )

    assert called is False
    assert sent[0]["status"] == 413


def test_request_body_limit_replays_valid_body_to_app():
    received = []

    async def app(scope, receive, send):
        received.append(await receive())
        received.append(await receive())
        await send({"type": "http.response.start", "status": 204, "headers": []})
        await send({"type": "http.response.body", "body": b""})

    middleware = RequestBodyLimitMiddleware(app, max_bytes=10)
    sent = run_asgi(
        middleware,
        http_scope(),
        [
            {"type": "http.request", "body": b"12345", "more_body": True},
            {"type": "http.request", "body": b"67890", "more_body": False},
        ],
    )

    assert received == [
        {"type": "http.request", "body": b"12345", "more_body": True},
        {"type": "http.request", "body": b"67890", "more_body": False},
    ]
    assert sent[0]["status"] == 204


def test_write_file_content_is_bounded():
    token = "machineid:0123456789abcdef"
    WriteFileRequest(token=token, path="large.txt", content="x" * MAX_WRITE_CONTENT_CHARS)

    with pytest.raises(ValidationError):
        WriteFileRequest(token=token, path="large.txt", content="x" * (MAX_WRITE_CONTENT_CHARS + 1))


def test_http_rate_limit_rejects_excess_api_requests_per_ip():
    async def app(scope, receive, send):
        await send({"type": "http.response.start", "status": 204, "headers": []})
        await send({"type": "http.response.body", "body": b""})

    middleware = HttpRateLimitMiddleware(app, max_requests=2)
    scope = http_scope(path="/api/read-file")
    incoming = [{"type": "http.request", "body": b"", "more_body": False}]

    assert run_asgi(middleware, scope, incoming)[0]["status"] == 204
    assert run_asgi(middleware, scope, incoming)[0]["status"] == 204
    limited = run_asgi(middleware, scope, incoming)
    assert limited[0]["status"] == 429
    assert (b"retry-after", b"60") in limited[0]["headers"]


def test_websocket_global_connection_limit(monkeypatch):
    monkeypatch.setattr(server, "MAX_WS_CONNECTIONS_GLOBAL", 2)
    state = ServerState()

    assert state.acquire_ws_slot("203.0.113.1") is None
    assert state.acquire_ws_slot("203.0.113.2") is None
    assert state.acquire_ws_slot("203.0.113.3") == "global_connection_limit"

    state.release_ws_slot("203.0.113.1")
    assert state.acquire_ws_slot("203.0.113.3") is None


def test_websocket_registration_closes_after_three_failed_hellos(monkeypatch):
    monkeypatch.setattr(server, "MAX_WS_HELLO_ATTEMPTS", 3)

    class FakeWebSocket:
        def __init__(self):
            self.client = SimpleNamespace(host="203.0.113.50", port=12345)
            self.headers = {}
            self.errors = []
            self.closed = None
            self.messages = iter(["not-json", "not-json", "not-json"])

        async def accept(self):
            pass

        async def receive_text(self):
            return next(self.messages)

        async def send_json(self, message):
            self.errors.append(message)

        async def close(self, *, code, reason):
            self.closed = (code, reason)

    websocket = FakeWebSocket()
    asyncio.run(agent_websocket(websocket))

    assert len(websocket.errors) == 3
    assert websocket.closed == (1008, "too many failed hello attempts")


def test_pending_request_global_limit(monkeypatch):
    monkeypatch.setattr(server, "MAX_PENDING_REQUESTS_GLOBAL", 1)
    state = ServerState()

    class FakeConnection:
        async def send_json(self, payload):
            raise AssertionError("request should be rejected before sending")

    async def run_test():
        loop = asyncio.get_running_loop()
        state.agents["machineid"] = FakeConnection()
        state.pending["existing"] = PendingRequest(
            request_id="existing",
            machine_id="othermachine",
            operation="readFile",
            future=loop.create_future(),
        )
        return await state.route_operation(
            "readFile",
            {"token": "machineid:0123456789abcdef", "path": "file.txt"},
            bridge_timeout=10,
        )

    status, body = asyncio.run(run_test())
    assert status == 503
    assert body["error"]["code"] == "server_busy"


def test_pending_request_per_agent_limit(monkeypatch):
    monkeypatch.setattr(server, "MAX_PENDING_REQUESTS_PER_AGENT", 1)
    state = ServerState()

    class FakeConnection:
        async def send_json(self, payload):
            raise AssertionError("request should be rejected before sending")

    async def run_test():
        loop = asyncio.get_running_loop()
        state.agents["machineid"] = FakeConnection()
        state.pending["existing"] = PendingRequest(
            request_id="existing",
            machine_id="machineid",
            operation="readFile",
            future=loop.create_future(),
        )
        return await state.route_operation(
            "readFile",
            {"token": "machineid:0123456789abcdef", "path": "file.txt"},
            bridge_timeout=10,
        )

    status, body = asyncio.run(run_test())
    assert status == 503
    assert body["error"]["code"] == "agent_busy"


def test_bridge_has_hard_pending_lifetime(monkeypatch):
    monkeypatch.setattr(server, "MAX_BRIDGE_PENDING_SECONDS", 0.01)
    state = ServerState()

    class FakeConnection:
        async def send_json(self, payload):
            pass

    async def run_test():
        state.agents["machineid"] = FakeConnection()
        return await state.route_operation(
            "executeCommand",
            {"token": "machineid:0123456789abcdef", "command": "sleep forever"},
            bridge_timeout=None,
        )

    status, body = asyncio.run(run_test())
    assert status == 504
    assert body["error"]["code"] == "bridge_timeout"
    assert state.pending == {}
