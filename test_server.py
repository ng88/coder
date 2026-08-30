import asyncio

import pytest
from pydantic import ValidationError

from server import MAX_WRITE_CONTENT_CHARS, RequestBodyLimitMiddleware, WriteFileRequest


def run_asgi(middleware, scope, incoming):
    sent = []
    messages = iter(incoming)

    async def receive():
        return next(messages)

    async def send(message):
        sent.append(message)

    asyncio.run(middleware(scope, receive, send))
    return sent


def http_scope(headers=None):
    return {
        "type": "http",
        "method": "POST",
        "path": "/test",
        "headers": headers or [],
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
