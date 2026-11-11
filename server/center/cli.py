"""`center` on the server's own machine: the owner's tools. They work on the database
directly, so they need no token and no running server.

  center serve [--host H] [--port P]     run the server (default 0.0.0.0:8110)
  center pairings                        the requests waiting for approval
  center approve <code>                  approve one (deny <code> refuses it)
  center token <name> <scope>...         make a token by hand, e.g. `center token me '*'`
  center tokens | center revoke <id>     list or revoke tokens
  center export <schema> > file.json     every live record of a schema
  center update                          a git checkout to the newest release (restart after)
  center import <schema> file.json       records from a list of {id?, data, updated_at?}
"""
from __future__ import annotations

import json
import sys
import time


def main(argv: list[str] | None = None) -> int:
    from . import auth, store
    args = list(sys.argv[1:] if argv is None else argv)
    cmd = args.pop(0) if args else "help"
    if cmd == "serve":
        import uvicorn
        host = args[args.index("--host") + 1] if "--host" in args else "0.0.0.0"
        port = int(args[args.index("--port") + 1]) if "--port" in args else 8110
        uvicorn.run("center.main:app", host=host, port=port)
    elif cmd == "pairings":
        rows = auth.pairings()
        for p in rows:
            age = int(time.time() - p["created_at"])
            print(f"{p['code']}  {p['app']:<20} {', '.join(p['scopes'])}  ({age}s ago)")
        if not rows:
            print("No pairing requests are waiting.")
    elif cmd in ("approve", "deny") and args:
        r = auth.decide(args[0], cmd == "approve")
        print(f"{r['app']}: {r['status']}")
    elif cmd == "token" and len(args) >= 2:
        tid, token = auth.create_token(args[0], args[1:])
        print(f"{tid}  {token}\nShown once; Center keeps only its hash.", file=sys.stderr)
        print(token)
    elif cmd == "tokens":
        for t in auth.tokens():
            state = "revoked" if t["revoked"] else "active"
            print(f"{t['id']}  {t['name']:<20} {', '.join(t['scopes']):<30} {state}")
    elif cmd == "revoke" and args:
        print("revoked" if auth.revoke(args[0]) else "no such token")
    elif cmd == "export" and args:
        json.dump(store.live(args[0]), sys.stdout, indent=2)
        print()
    elif cmd == "update":
        from . import updates
        st = updates.status()
        print(f"on {st['current']}; newest release {(st['latest'] or {}).get('version', 'unknown')}")
        print(f"now on {updates.run_update()}. Restart the server to use it.")
    elif cmd == "import" and len(args) == 2:
        import uuid
        from .schemas import BY_NAME
        schema = BY_NAME[args[0]]
        n = 0
        for item in json.load(open(args[1])):
            data = schema.model(**item["data"]).model_dump()
            store.put(schema.name, item.get("id") or uuid.uuid4().hex, data, item.get("updated_at"))
            n += 1
        print(f"imported {n} {schema.name}")
    else:
        print(__doc__)
        return 0 if cmd == "help" else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
