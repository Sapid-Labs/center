"""Live changes: `GET /v1/events` is a server-sent event stream, one event per write.

An event says which record changed, not what it now holds: `{"schema", "id", "seq",
"deleted"}`. An app then pulls `GET /v1/<schema>?since=<its cursor>`, the same call it
makes at start, so there is one way to sync and the stream only says when.
"""
from __future__ import annotations

import asyncio
import json
import threading


class Hub:
    def __init__(self) -> None:
        self._subs: set[tuple[asyncio.Queue, asyncio.AbstractEventLoop, frozenset[str]]] = set()
        self._lock = threading.Lock()

    def subscribe(self, schemas: frozenset[str]) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=1000)
        with self._lock:
            self._subs.add((q, asyncio.get_running_loop(), schemas))
        return q

    def unsubscribe(self, q: asyncio.Queue) -> None:
        with self._lock:
            self._subs = {s for s in self._subs if s[0] is not q}

    def publish(self, event: dict) -> None:
        """Safe from any thread: request handlers run in a thread pool."""
        with self._lock:
            subs = list(self._subs)
        for q, loop, schemas in subs:
            if event["schema"] in schemas:
                loop.call_soon_threadsafe(_offer, q, event)


def _offer(q: asyncio.Queue, event: dict) -> None:
    try:
        q.put_nowait(event)
    except asyncio.QueueFull:
        pass   # A stalled listener misses events, not changes: its next pull catches up.


hub = Hub()


def frame(event: dict) -> str:
    return f"event: change\ndata: {json.dumps(event)}\n\n"
