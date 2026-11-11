# Changelog

Releases are tags `vX.Y.Z`; each publishes `ghcr.io/sapid-labs/center:X.Y.Z`. Within an
`api` version a schema only gains optional fields, so an app written for an older Center
keeps working and data written by an older Center stays readable.

## 0.2.0 (2026-11-11)

- **The owner's page** at `/`: approve or deny the apps that ask to connect, see and
  revoke the connected ones, see what the Center holds, and update it.
- **Updates**: `GET/POST /v1/admin/update` and `center update`. A git checkout updates
  itself to the newest release; a Docker install pulls the new image.
- **The work area**: `work.profile`, `work.experiences`, `work.stories` (STAR answers,
  with a `lesson`) and `work.applications`. A token with `work:read` or `work:write`
  covers them all.
- **CORS**, so web apps can call a Center.
- A PUT with a new id for a record that has the same natural key updates that record.

## 0.1.0 (2026-11-10)

- Records, pairing, the changes feed and live events; `corrections`.
