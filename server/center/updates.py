"""Keeping a Center up to date (0.2.0).

Releases are tags `vX.Y.Z` on github.com/Sapid-Labs/center, each with a Docker image
`ghcr.io/sapid-labs/center:X.Y.Z` (and `latest`). How a Center updates depends on how it
was installed:

- **Docker** (`CENTER_INSTALL=docker`, set in the image): pull the new image. An
  auto-updater such as Watchtower does it on its own.
- **A git checkout** (the folder holds `.git`): `center update` fetches the tags, checks
  out the newest release and syncs the dependencies; the owner page's Update button does
  the same, then restarts the server (its service manager starts it again).

Updates never lose data: records are stored as JSON beside their schema name, and a
release may add fields to a schema but not remove or rename one within the same `api`.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
import urllib.request
from pathlib import Path

from . import VERSION

REPO = "Sapid-Labs/center"
ROOT = Path(__file__).resolve().parents[2]
_cache: dict = {"at": 0.0, "latest": None}


def parse(v: str) -> tuple[int, ...]:
    try:
        return tuple(int(x) for x in v.strip().lstrip("v").split("."))
    except ValueError:
        return (0,)


def how() -> str:
    if os.environ.get("CENTER_INSTALL") == "docker":
        return "docker"
    return "git" if (ROOT / ".git").exists() else "none"


def latest(max_age: float = 3600) -> dict | None:
    """The newest release `{version, notes, url}`, asked of GitHub at most hourly."""
    if time.time() - _cache["at"] < max_age:
        return _cache["latest"]
    try:
        req = urllib.request.Request(f"https://api.github.com/repos/{REPO}/releases/latest",
                                     headers={"Accept": "application/vnd.github+json", "User-Agent": "center"})
        with urllib.request.urlopen(req, timeout=10) as r:
            d = json.load(r)
        _cache["latest"] = {"version": d["tag_name"].lstrip("v"), "notes": d.get("body") or "",
                            "url": d.get("html_url")}
    except Exception:  # noqa: BLE001 -- offline, or no release yet: no update to offer
        _cache["latest"] = None
    _cache["at"] = time.time()
    return _cache["latest"]


def status() -> dict:
    new = latest()
    available = bool(new and parse(new["version"]) > parse(VERSION))
    return {"current": VERSION, "latest": new, "available": available, "how": how()}


def run_update() -> str:
    """A git checkout to the newest release. Returns the version it is now on."""
    if how() != "git":
        raise RuntimeError("Only a git checkout updates itself; a Docker install pulls the new image.")
    git = lambda *a: subprocess.run(["git", "-C", str(ROOT), *a], check=True, capture_output=True, text=True).stdout  # noqa: E731
    git("fetch", "--tags", "--force", "--quiet", "origin")
    tags = [t for t in git("tag", "--list", "v*").split() if parse(t) > (0,)]
    if not tags:
        raise RuntimeError("No releases found.")
    newest = max(tags, key=parse)
    git("checkout", "--quiet", newest)
    uv = shutil.which("uv") or str(Path.home() / ".local/bin/uv")
    subprocess.run([uv, "sync", "--no-dev", "--quiet"], cwd=ROOT / "server", check=True)
    return newest.lstrip("v")
