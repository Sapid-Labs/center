"""The schemas Center serves. Each is a module with a `SCHEMA`; add one to `ALL`.

Center is not a free-form store: every kind of record it keeps is declared here, with
its pydantic model, so every app that reads a record can trust its shape.
"""
from .base import Schema
from . import corrections, work

ALL: list[Schema] = [corrections.SCHEMA, work.PROFILE, work.EXPERIENCES, work.STORIES,
                     work.APPLICATIONS]
BY_NAME = {s.name: s for s in ALL}
