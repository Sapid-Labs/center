"""The work area (2026-11-10), owned by Relevant: the person's job search as they carry
it from app to app. Job leads themselves are a Loopwork server's items; what lands here
is what the person keeps.

- `work.profile`: one record, id `me`: who they are as a candidate.
- `work.experiences`: jobs they have had.
- `work.stories`: STAR answers to interview questions, reusable across applications.
- `work.applications`: jobs they applied to, and where each stands. Natural key: `url`.
"""
from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, Field

from .base import Schema


class Source(BaseModel):
    """Where a record came from: an app, and that app's own ids."""
    app: str = Field(max_length=60)
    loop_id: Optional[str] = Field(None, max_length=120)
    item_id: Optional[str] = Field(None, max_length=120)


class Profile(BaseModel):
    headline: str = Field("", max_length=200)
    summary: str = Field("", max_length=4000)
    skills: list[str] = Field(default_factory=list, max_length=200)
    roles: list[str] = Field(default_factory=list, max_length=50, description="roles they want")
    locations: list[str] = Field(default_factory=list, max_length=50)
    remote: Optional[Literal["remote", "hybrid", "on-site", "any"]] = None
    seniority: Optional[str] = Field(None, max_length=40)
    salary_min: Optional[int] = Field(None, ge=0)
    links: list[str] = Field(default_factory=list, max_length=20)


class Experience(BaseModel):
    company: str = Field(min_length=1, max_length=200)
    title: str = Field(min_length=1, max_length=200)
    start: Optional[str] = Field(None, max_length=20, description="YYYY-MM")
    end: Optional[str] = Field(None, max_length=20, description="YYYY-MM, empty while current")
    summary: str = Field("", max_length=4000)
    highlights: list[str] = Field(default_factory=list, max_length=50)


class Story(BaseModel):
    """A STAR answer."""
    title: str = Field(min_length=1, max_length=200, description="the question it answers, or a short name")
    situation: str = Field("", max_length=4000)
    task: str = Field("", max_length=4000)
    action: str = Field("", max_length=8000)
    result: str = Field("", max_length=4000)
    lesson: str = Field("", max_length=4000, description="what they took from it")
    skills: list[str] = Field(default_factory=list, max_length=50)
    tags: list[str] = Field(default_factory=list, max_length=50)
    experience_id: Optional[str] = Field(None, max_length=120)


class Application(BaseModel):
    company: str = Field(min_length=1, max_length=200)
    title: str = Field(min_length=1, max_length=200)
    url: str = Field(min_length=1, max_length=2000)
    status: Literal["saved", "applied", "interviewing", "offer", "rejected", "withdrawn"] = "applied"
    applied_at: Optional[float] = None
    next_step: str = Field("", max_length=1000)
    notes: str = Field("", max_length=8000)
    story_ids: list[str] = Field(default_factory=list, max_length=50)
    source: Optional[Source] = None


PROFILE = Schema(name="work.profile", version=1, model=Profile,
                 description="Who the person is as a candidate (one record, id `me`)")
EXPERIENCES = Schema(name="work.experiences", version=1, model=Experience,
                     description="Jobs the person has had")
STORIES = Schema(name="work.stories", version=1, model=Story,
                 description="STAR answers to interview questions")
APPLICATIONS = Schema(name="work.applications", version=1, model=Application,
                      description="Jobs the person applied to, and where each stands",
                      key=lambda a: a.url.strip().lower())
