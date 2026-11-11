# Center

Center is a private server that a person's apps share data through. Every app works on
its own. An app that is pointed at a Center also shares data with the person's other
apps: a transcription correction made in Clibbits fixes the next dictation in Herald, on
the Mac and on the phone.

Each person runs their own Center. Center is not a hosted service.

Center is also a protocol. An app can serve the schemas it owns with the same API, so
apps on one Mac talk to each other directly, with no server running. See
[docs/protocol.md](docs/protocol.md). How Center fits with the apps and with services
such as a Loopwork server is in [docs/system.md](docs/system.md).

## How it fits together

- **Each app keeps its own data.** An app works with no Center at all. When the app is
  connected, it pushes its changes to Center and pulls the changes other apps made.
- **Center serves a fixed list of schemas.** Each schema is a module in
  `server/center/schemas/` with a pydantic model, so every app can trust the shape of a
  record. The first schema is `corrections`. Notes and models come next.
- **One sync call per schema.** `GET /v1/<schema>?since=<cursor>` returns every record
  written after the cursor, deletes included, oldest first, and the cursor to send
  next time. An app makes this call at start and whenever Center tells it something
  changed.
- **Live changes.** `GET /v1/events` is a server-sent event stream with one event per
  write. An event names the record that changed. The app then pulls the changes.
- **Last write wins.** An app sends `updated_at`, the time the app made the change.
  Center ignores a write that is older than the stored record.
- **Every app has its own token.** The app pairs with Center, and the owner approves the
  pairing on the server. A token carries scopes such as `corrections:read` or
  `corrections:write`, and the owner can revoke it.

## The API

`GET /docs` on a running Center shows the full OpenAPI spec.

| Call | Token | What |
|---|---|---|
| `GET /v1` | none | the Center's name, version and schemas. An app calls this first |
| `POST /v1/pair` `{app, scopes}` | none | ask to pair. The response has a `code` for the owner to approve and a `pairing_id` |
| `GET /v1/pair/<pairing_id>` | none | poll the pairing. Once it is approved, the response has the token, one time only |
| `GET /v1/<schema>?since=&limit=` | read | changes after the cursor: `{items, cursor, more}` |
| `GET /v1/<schema>/<id>` | read | one record |
| `POST /v1/<schema>` `{data, updated_at?}` | write | add a record. A record with the same natural key is replaced |
| `PUT /v1/<schema>/<id>` `{data, updated_at?}` | write | add or replace a record by the app's own id |
| `DELETE /v1/<schema>/<id>` | write | delete a record. Center keeps a tombstone so that the delete syncs |
| `GET /v1/events?schemas=` | read | server-sent events: `{schema, id, seq, deleted}` |
| `GET /v1/me` | any | the calling token's name and scopes |
| `/v1/admin/pairings`, `/v1/admin/tokens` | `*` | approve or deny pairings, and list or revoke tokens |

A record is `{id, data, created_at, updated_at, deleted, seq}`. `data` is the schema's
own model.

### corrections

`data` is `{original, correction, enabled, source}`. `original` is what the transcriber
writes, and `correction` is what was said. The natural key is `original`, case ignored.
Matching is whole words, case ignored, longest phrase first.
`POST /v1/corrections/apply` `{text}` applies the corrections on the server.

### work (Relevant's)

`work.profile` (one record, id `me`), `work.experiences`, `work.stories` (STAR answers)
and `work.applications` (natural key `url`). A token with `work:read` or `work:write`
covers every `work.*` schema.

## Running it

```bash
cd server
uv sync
uv run center serve --port 8110      # data in ~/.local/share/center (CENTER_DATA)
# Joe's: center.service on chonky; over HTTPS on the tailnet only (for web apps):
# sudo tailscale serve --bg --https=8111 http://127.0.0.1:8110
#   -> https://chonky.tail5695fc.ts.net:8111
uv run center pairings               # pairing requests that are waiting
uv run center approve K7Q-2MX        # approve one
uv run center token me '*'           # an owner token, made by hand
```

With Docker:

```bash
docker build -t center . && docker run -d -p 8110:8110 -v center-data:/data center
```

## Adding a schema

1. Add a module to `server/center/schemas/` with a pydantic model and a `SCHEMA`.
2. Add the schema to `ALL` in `schemas/__init__.py`.
3. Add tests.

The schema gets the sync, write and delete calls, its scopes and its events from
`schemas/base.py`.
