"""What every schema gets, and the calls made from it.

For a schema named `things` with model `Thing`:

| Call | What |
|---|---|
| `GET /v1/things?since=<seq>&limit=` | changes after `since`, tombstones included, oldest first, and the `cursor` to send next time. `since=0` is everything |
| `GET /v1/things/<id>` | one record |
| `POST /v1/things` | add one; Center gives it an id (or merges it into the record with the same natural key, see `key`) |
| `PUT /v1/things/<id>` | add or replace one by the app's own id (a new id with the natural key of a record already here updates that record; the response has its id). `updated_at` in the body is when the app made the change; an older change than the stored one is ignored (last write wins) |
| `DELETE /v1/things/<id>` | delete (keeps a tombstone so the delete syncs) |

`<schema>:read` covers the GETs, `<schema>:write` the rest.
"""

import time
import uuid
from dataclasses import dataclass, field
from typing import Callable, Generic, Optional, TypeVar

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

from .. import auth, store
from ..events import hub

T = TypeVar("T", bound=BaseModel)


class Record(BaseModel, Generic[T]):
    id: str
    data: Optional[T] = None
    created_at: float
    updated_at: float
    deleted: bool
    seq: int


class Page(BaseModel, Generic[T]):
    items: list[Record[T]]
    cursor: int
    more: bool


class Write(BaseModel, Generic[T]):
    data: T
    updated_at: Optional[float] = None


@dataclass
class Schema:
    name: str
    version: int
    model: type[BaseModel]
    description: str
    # A natural key: two records with the same key are the same thing ("Abby" corrected
    # twice is one correction). POST merges into the live record with the same key.
    key: Optional[Callable[[BaseModel], str]] = None
    extra: Optional[APIRouter] = None
    routes: APIRouter = field(init=False)

    def __post_init__(self) -> None:
        self.routes = _router(self)


def _publish(schema: str, rec: dict) -> None:
    hub.publish({"schema": schema, "id": rec["id"], "seq": rec["seq"], "deleted": rec["deleted"]})


def _router(s: Schema) -> APIRouter:
    M = s.model
    r = APIRouter(prefix=f"/v1/{s.name}", tags=[s.name])
    read, write = auth.require(f"{s.name}:read"), auth.require(f"{s.name}:write")

    def same_key(data: BaseModel) -> Optional[dict]:
        if s.key is None:
            return None
        k = s.key(data)
        return next((x for x in store.live(s.name) if s.key(M(**x["data"])) == k), None)

    @r.get("", response_model=Page[M], summary=f"{s.name} changed since a cursor")
    def changes(since: int = Query(0, ge=0), limit: int = Query(500, ge=1, le=5000), _=Depends(read)):
        items = store.changes(s.name, since, limit + 1)
        more = len(items) > limit
        items = items[:limit]
        cursor = items[-1]["seq"] if items else max(since, 0)
        return {"items": items, "cursor": cursor, "more": more}

    @r.get("/{rid}", response_model=Record[M])
    def one(rid: str, _=Depends(read)):
        rec = store.get(s.name, rid)
        if rec is None:
            raise HTTPException(404, f"No such {s.name} record.")
        return rec

    @r.post("", response_model=Record[M])
    def add(body: Write[M], _=Depends(write)):
        existing = same_key(body.data)
        rid = existing["id"] if existing else uuid.uuid4().hex
        rec, changed = store.put(s.name, rid, body.data.model_dump(), body.updated_at)
        if changed:
            _publish(s.name, rec)
        return rec

    @r.put("/{rid}", response_model=Record[M])
    def replace(rid: str, body: Write[M], _=Depends(write)):
        # A new id for something already here under another id (the same natural key)
        # updates that record, so two apps that each made "Abby" leave one correction.
        # The response's id says which record it was.
        if store.get(s.name, rid) is None and (existing := same_key(body.data)) is not None:
            rid = existing["id"]
        rec, changed = store.put(s.name, rid, body.data.model_dump(), body.updated_at)
        if changed:
            _publish(s.name, rec)
        return rec

    @r.delete("/{rid}", response_model=Record[M])
    def delete(rid: str, updated_at: Optional[float] = None, _=Depends(write)):
        old = store.get(s.name, rid)
        if old is None:
            raise HTTPException(404, f"No such {s.name} record.")
        rec, changed = store.put(s.name, rid, old["data"], updated_at or time.time(), deleted=True)
        if changed:
            _publish(s.name, rec)
        return rec

    if s.extra is not None:
        r.include_router(s.extra)
    return r
