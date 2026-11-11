# The system

Three kinds of program make up the system. Each repo that is part of it links here.

| Box | What it does | Run by |
|---|---|---|
| **Center** | stores the person's own data, which they take to every app | the person, on a machine they own |
| **Services** | do work for apps. The first service is a Loopwork server, which runs loops | the person, or a host they trust |
| **Apps** | one app per area of the person's life, each with its own UI | anyone; every app works on its own |

## Center: the person's data

Center keeps what is known about the person, grouped into areas. Each area has one or
more schemas, and one app owns each area:

| Area | Schemas (planned unless marked) | Owning app |
|---|---|---|
| utility | `corrections` (built) | Herald |
| work | job leads, applications, STAR stories, experiences, profile | Relevant |
| health | measurements, labs and their PDFs, supplements, concerns | a health app |
| people | contacts | a contacts app |
| notes | notes and ideas | a notes app |

Center holds four kinds of content: records (typed JSON), documents (Markdown),
files (PDFs, images) and measurements (timestamped numbers). Only records exist today.

## Apps: one per area

The owning app is where the person edits an area's data. Other apps only use that data.
For example, Clibbits sends a correction to Herald.

- **With a Center server set,** every app reads and writes through Center alone.
- **With no Center server,** the apps on one Mac talk to each other directly. An app
  that owns a schema serves it from its own node, and the other apps find that node
  over Bonjour.

[protocol.md](protocol.md) describes both setups. CenterKit is the protocol's Swift
package, in `swift/CenterKit`.

## Services: a Loopwork server

A Loopwork server runs loops. A loop plays a sequence of steps on a schedule, with a
review every few runs, and it may collect items in a schema that the app defines. The
loop runs an agent inside the loop's own folder. The template declares that folder's
layout: the inputs the app provides, and the memory, output and tools that the agent
keeps. Loopwork's `docs/design.md` ("Loopwork as a server") has the API.

- **Trinkets** is a general app for viewing collected items, and also a hosted
  Loopwork server.
- **Relevant** finds jobs with a job template on a Loopwork server. Relevant keeps
  applications and STAR stories in the person's Center.
- A news app, a GPU finder or a recipe finder each registers its own template.

## How an app connects

An app's settings have up to three addresses:

1. **Center server:** optional. The person's data.
2. **Apps:** apps found on the same Mac, or added by address. These are used only when
   no Center server is set.
3. **Services:** a Loopwork server, for apps that need loops. For Relevant this setting
   is required.

The app sends what it knows about the person, such as skills or a resume, to the loop
as input files. The app sends these itself because the Loopwork server usually cannot
reach a personal Center server.
