import asyncio

import pytest
from pydantic import ValidationError

from server import HttpRateLimitMiddleware, MAX_WRITE_CONTENT_CHARS, RequestBodyLimitMiddleware, WriteFileRequest


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
