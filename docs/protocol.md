# The Center protocol

The Center protocol is the API in the README: `GET /v1`, pairing, and the calls for each
schema. Two kinds of program speak it.

- **The Center server** serves every schema. A person runs one on a machine they own.
- **An app** serves the schemas it owns. Herald owns `corrections`, so the Herald Mac app
  serves `GET /v1`, pairing and `/v1/corrections` on the same Mac. Clibbits owns no
  schema yet, so Clibbits only calls other programs.

The Center server and the apps are all **nodes**. A node that serves a schema accepts
writes to that schema from any paired app. Apps form small networks of their own, with
no Center server involved. A Center server joins the network like any other node.

## Settings in every app

Every app that speaks the protocol has the same two settings.

1. **Center.** One URL, empty by default. When the URL is set, the app syncs every
   schema it uses with that Center.
2. **Apps.** A list of other nodes, each with a URL and a token. On a Mac the list fills
   itself: every node advertises itself over Bonjour as `_center._tcp` on the same Mac.
   The person can also add a URL by hand, for example an app on another machine.

`GET /v1` on each node returns the schemas that node serves. An app offers a feature only
when some node it is connected to serves the schema behind that feature. For example,
Clibbits shows "Correct in Herald…" only when a connected node serves `corrections`.

## Writes go to every node that serves the schema

When an app makes a record, it gives the record an id and sends
`PUT /v1/<schema>/<id>` to every connected node that serves the schema. For a correction
made in Clibbits, those nodes are the Herald Mac app and the Center server, if one is set.
A node that gets the same record twice keeps one copy, because the id is the same. When
two copies differ, the copy with the later `updated_at` wins.

A node that owns a schema and has a Center set syncs that schema with the Center:

- The node pushes its own changes to the Center.
- The node pulls the changes that other nodes made, with `GET /v1/<schema>?since=`.

The Herald phone app reaches the Mac only through a Center server, because a phone cannot
serve the protocol to a Mac.

## Pairing between apps

Pairing between apps works as it does with the Center server. The node that receives the
request shows the code in its own window. For example, Herald shows "Clibbits wants to
add corrections. Code K7Q-2MX. Allow?" The person approves the request in that window.

An app's node listens on `127.0.0.1` by default. Listening on the local network is a
setting, and each app on the network still has to pair.

## Parts every app shares

- **CenterKit** (Swift) is a Swift package with three parts:
  - the client: `GET /v1`, pairing, writes to every node, and the sync loop
  - the local node: an `NWListener` HTTP server, the Bonjour advert, and the pairing
    prompt
  - the settings view: the Center URL and the Apps list
- **A Kotlin client** for Android apps. A phone app connects through a Center server
  only.

The schemas are defined once, in `server/center/schemas/`. CenterKit's model types for
each schema must match those definitions.
