"""Transcription corrections: "heard X, meant Y".

Any app that turns speech into text applies them (Herald on the Mac and the phone), and
any app may add one (Herald's Fix chip, Clibbits' "Correct in Herald…"). Matching is
whole words, case ignored, longest phrase first; `POST /v1/corrections/apply` does it
here for an app that would rather not.

The natural key is `original`, case ignored: correcting "Abby" again replaces the first
correction rather than adding a second.
"""
from __future__ import annotations

import re

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from .. import auth, store
from .base import Schema


class Correction(BaseModel):
    original: str = Field(min_length=1, max_length=200, description="What the transcriber writes")
    correction: str = Field(min_length=1, max_length=200, description="What was said")
    enabled: bool = True
    source: str | None = Field(None, max_length=60, description="The app it came from, e.g. clibbits")


class ApplyIn(BaseModel):
    text: str


class ApplyOut(BaseModel):
    text: str
    count: int


def apply(text: str, rules: list[dict]) -> tuple[str, int]:
    total = 0
    for c in sorted((r for r in rules if r.get("enabled", True) and r["original"].strip()),
                    key=lambda r: -len(r["original"])):
        pat = re.compile(r"(?<![\w'])" + re.escape(c["original"].strip()) + r"(?![\w'])", re.IGNORECASE)
        text, n = pat.subn(lambda _m, rep=c["correction"]: rep, text)
        total += n
    return text, total


extra = APIRouter()


@extra.post("/apply", response_model=ApplyOut)
def apply_call(body: ApplyIn, _=Depends(auth.require("corrections:read"))):
    text, n = apply(body.text, [r["data"] for r in store.live("corrections")])
    return {"text": text, "count": n}


SCHEMA = Schema(
    name="corrections",
    version=1,
    model=Correction,
    description='Transcription corrections: "heard X, meant Y"',
    key=lambda c: c.original.strip().lower(),
    extra=extra,
)
