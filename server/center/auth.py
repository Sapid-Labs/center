"""Who may call: app tokens with scopes, handed out by pairing.

Every call but `GET /v1` and the pairing calls needs `Authorization: Bearer <token>`.
A token carries scopes, `<schema>:read` and `<schema>:write` (write implies read), or
`*` for everything, which the owner's own tools use.

PAIRING. An app that is pointed at a Center asks to pair (`POST /v1/pair` with its name
and the scopes it wants) and shows the owner a short code. The owner approves the code
on the server (`center approve <code>`, or `POST /v1/admin/pairings/<id>/approve` with a
`*` token). The app polls `GET /v1/pair/<id>` and collects its token once; Center keeps
only a hash of it after that. A request not approved in ten minutes expires.
"""
from __future__ import annotations

import hashlib
import json
import secrets
import time
import uuid

from fastapi import Depends, HTTPException, Request

from . import store

PAIRING_TTL = 600
_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"   # no 0/O, 1/I/L


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def create_token(name: str, scopes: list[str]) -> tuple[str, str]:
    """A new token: (id, the token itself, shown this once)."""
    token = "ctr_" + secrets.token_urlsafe(32)
    tid = uuid.uuid4().hex[:12]
    with store._lock:
        store.db().execute("INSERT INTO tokens VALUES (?, ?, ?, ?, ?, NULL, 0)",
                           (tid, name, _hash(token), json.dumps(scopes), time.time()))
    return tid, token


def tokens() -> list[dict]:
    return [{"id": r["id"], "name": r["name"], "scopes": json.loads(r["scopes"]),
             "created_at": r["created_at"], "last_used_at": r["last_used_at"],
             "revoked": bool(r["revoked"])}
            for r in store.db().execute("SELECT * FROM tokens ORDER BY created_at")]


def revoke(tid: str) -> bool:
    with store._lock:
        return store.db().execute("UPDATE tokens SET revoked = 1 WHERE id = ?", (tid,)).rowcount > 0


def allows(scopes: list[str], need: str) -> bool:
    """`<schema>:read|write`, write covering read; an area's scope (`work:write`) covers
    each of its schemas (`work.stories`)."""
    if "*" in scopes or need in scopes:
        return True
    schema, _, mode = need.partition(":")
    names = [schema] + ([schema.split(".")[0]] if "." in schema else [])
    return any(f"{n}:{mode}" in scopes or (mode == "read" and f"{n}:write" in scopes) for n in names)


def caller(request: Request) -> dict:
    header = request.headers.get("authorization", "")
    token = header[7:].strip() if header.lower().startswith("bearer ") else request.query_params.get("token", "")
    if not token:
        raise HTTPException(401, "Pair this app with Center first: no token was sent.")
    r = store.db().execute("SELECT * FROM tokens WHERE hash = ? AND revoked = 0", (_hash(token),)).fetchone()
    if r is None:
        raise HTTPException(401, "This token is not one Center knows, or it was revoked.")
    with store._lock:
        store.db().execute("UPDATE tokens SET last_used_at = ? WHERE id = ?", (time.time(), r["id"]))
    return {"id": r["id"], "name": r["name"], "scopes": json.loads(r["scopes"])}


def require(scope: str):
    def check(who: dict = Depends(caller)) -> dict:
        if not allows(who["scopes"], scope):
            raise HTTPException(403, f"This app's token does not allow {scope}.")
        return who
    return check


# --- pairing ---------------------------------------------------------------------------

def start_pairing(app: str, scopes: list[str]) -> dict:
    now = time.time()
    with store._lock:
        c = store.db()
        c.execute("UPDATE pairings SET status = 'expired', token = NULL "
                  "WHERE status IN ('waiting', 'approved') AND created_at < ?", (now - PAIRING_TTL,))
        if c.execute("SELECT count(*) FROM pairings WHERE status = 'waiting'").fetchone()[0] >= 20:
            raise HTTPException(429, "Too many pairing requests are waiting. Try again in a few minutes.")
        pid = uuid.uuid4().hex
        code = "".join(secrets.choice(_ALPHABET) for _ in range(6))
        code = f"{code[:3]}-{code[3:]}"
        c.execute("INSERT INTO pairings VALUES (?, ?, ?, ?, ?, 'waiting', NULL)",
                  (pid, code, app, json.dumps(scopes), now))
    return {"pairing_id": pid, "code": code, "expires_in": PAIRING_TTL}


def pairings(waiting_only: bool = True) -> list[dict]:
    q = "SELECT * FROM pairings WHERE created_at > ?" + (" AND status = 'waiting'" if waiting_only else "")
    return [{"id": r["id"], "code": r["code"], "app": r["app"], "scopes": json.loads(r["scopes"]),
             "created_at": r["created_at"], "status": r["status"]}
            for r in store.db().execute(q + " ORDER BY created_at", (time.time() - PAIRING_TTL,))]


def decide(pid_or_code: str, approve: bool) -> dict:
    key = pid_or_code.strip().upper().replace(" ", "")
    if len(key) == 6:
        key = f"{key[:3]}-{key[3:]}"
    with store._lock:
        c = store.db()
        r = c.execute("SELECT * FROM pairings WHERE (id = ? OR code = ?) AND status = 'waiting' AND created_at > ?",
                      (pid_or_code, key, time.time() - PAIRING_TTL)).fetchone()
        if r is None:
            raise HTTPException(404, "No pairing request is waiting with that code.")
        token = None
        if approve:
            _, token = create_token(r["app"], json.loads(r["scopes"]))
        c.execute("UPDATE pairings SET status = ?, token = ? WHERE id = ?",
                  ("approved" if approve else "denied", token, r["id"]))
    return {"id": r["id"], "app": r["app"], "status": "approved" if approve else "denied"}


def collect(pid: str) -> dict:
    """The app's poll. An approved token is handed over once, then forgotten here."""
    with store._lock:
        c = store.db()
        r = c.execute("SELECT * FROM pairings WHERE id = ?", (pid,)).fetchone()
        if r is None:
            raise HTTPException(404, "No such pairing request.")
        status = r["status"]
        if status == "waiting" and r["created_at"] < time.time() - PAIRING_TTL:
            status = "expired"
        if status == "approved":
            c.execute("UPDATE pairings SET status = 'collected', token = NULL WHERE id = ?", (pid,))
            return {"status": "approved", "token": r["token"]}
    return {"status": status}
