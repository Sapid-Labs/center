"""The Center server: `uvicorn center.main:app` (or `center serve`)."""
from __future__ import annotations

import asyncio
import os
from typing import Optional

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from . import VERSION, auth, store
from .events import frame, hub
from .schemas import ALL, BY_NAME

app = FastAPI(title="Center", version=VERSION,
              description="One private server that the apps you run share data through.")
for s in ALL:
    app.include_router(s.routes)

NAME = os.environ.get("CENTER_NAME", "Center")


@app.get("/v1", tags=["center"])
def about():
    """What this Center is and which schemas it serves. No token needed: an app calls
    this first to know it is talking to a Center, and which of its features will work."""
    return {"center": NAME, "version": VERSION, "api": 1,
            "schemas": {s.name: {"version": s.version, "description": s.description} for s in ALL}}


@app.get("/health", include_in_schema=False)
def health():
    store.db()
    return {"ok": True}


class PairIn(BaseModel):
    app: str = Field(min_length=1, max_length=60, description="The app's name, shown to the owner")
    scopes: list[str] = Field(min_length=1, description='e.g. ["corrections:write"]')


@app.post("/v1/pair", tags=["pairing"])
def pair(body: PairIn):
    for sc in body.scopes:
        schema, _, mode = sc.partition(":")
        if schema not in BY_NAME or mode not in ("read", "write"):
            raise HTTPException(400, f"Center has no scope {sc!r}.")
    return auth.start_pairing(body.app.strip(), body.scopes)


@app.get("/v1/pair/{pid}", tags=["pairing"])
def pair_status(pid: str):
    return auth.collect(pid)


@app.get("/v1/me", tags=["center"])
def me(who: dict = Depends(auth.caller)):
    return who


@app.get("/v1/events", tags=["center"])
async def events(request: Request, schemas: Optional[str] = Query(None, description="comma separated"),
                 who: dict = Depends(auth.caller)):
    """A server-sent event per change in the schemas this token may read."""
    want = [x for x in (schemas.split(",") if schemas else BY_NAME) if x in BY_NAME]
    allowed = frozenset(x for x in want if auth.allows(who["scopes"], f"{x}:read"))
    if not allowed:
        raise HTTPException(403, "This token may read none of those schemas.")
    q = hub.subscribe(allowed)

    async def stream():
        try:
            yield "retry: 3000\n\n"
            while not await request.is_disconnected():
                try:
                    yield frame(await asyncio.wait_for(q.get(), 15))
                except asyncio.TimeoutError:
                    yield ": keep-alive\n\n"
        finally:
            hub.unsubscribe(q)

    return StreamingResponse(stream(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


# --- the owner's calls (a `*` token) -----------------------------------------------------

owner = auth.require("*")


@app.get("/v1/admin/pairings", tags=["admin"])
def admin_pairings(_=Depends(owner)):
    return auth.pairings()


@app.post("/v1/admin/pairings/{pid}/approve", tags=["admin"])
def admin_approve(pid: str, _=Depends(owner)):
    return auth.decide(pid, True)


@app.post("/v1/admin/pairings/{pid}/deny", tags=["admin"])
def admin_deny(pid: str, _=Depends(owner)):
    return auth.decide(pid, False)


@app.get("/v1/admin/tokens", tags=["admin"])
def admin_tokens(_=Depends(owner)):
    return auth.tokens()


@app.delete("/v1/admin/tokens/{tid}", tags=["admin"])
def admin_revoke(tid: str, _=Depends(owner)):
    if not auth.revoke(tid):
        raise HTTPException(404, "No such token.")
    return {"revoked": tid}
