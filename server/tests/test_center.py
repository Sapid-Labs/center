from center import auth


def test_about_needs_no_token_and_lists_the_schemas(client):
    r = client.get("/v1").json()
    assert r["api"] == 1 and "corrections" in r["schemas"]


def test_everything_else_needs_a_token_with_the_right_scope(client, token):
    assert client.get("/v1/corrections").status_code == 401
    assert client.get("/v1/corrections", headers={"Authorization": "Bearer nope"}).status_code == 401
    assert client.get("/v1/corrections", headers=token("notes:read")).status_code == 403
    assert client.get("/v1/corrections", headers=token("corrections:write")).status_code == 200
    ro = token("corrections:read")
    assert client.post("/v1/corrections", json={"data": {"original": "a", "correction": "b"}}, headers=ro).status_code == 403


def test_a_correction_added_twice_is_one_correction(client, token):
    h = token("corrections:write")
    a = client.post("/v1/corrections", json={"data": {"original": "Abby", "correction": "Abi"}}, headers=h).json()
    b = client.post("/v1/corrections", json={"data": {"original": "abby", "correction": "Abbie"}}, headers=h).json()
    assert a["id"] == b["id"] and b["data"]["correction"] == "Abbie"
    assert [x["data"]["correction"] for x in client.get("/v1/corrections", headers=h).json()["items"]] == ["Abbie"]


def test_the_changes_feed_has_deletes_and_a_cursor(client, token):
    h = token("corrections:write")
    a = client.post("/v1/corrections", json={"data": {"original": "chunky", "correction": "Chonky"}}, headers=h).json()
    page = client.get("/v1/corrections", headers=h).json()
    cur = page["cursor"]
    assert client.get(f"/v1/corrections?since={cur}", headers=h).json()["items"] == []
    client.delete(f"/v1/corrections/{a['id']}", headers=h)
    later = client.get(f"/v1/corrections?since={cur}", headers=h).json()
    assert [(x["id"], x["deleted"]) for x in later["items"]] == [(a["id"], True)]
    assert later["cursor"] > cur


def test_last_write_wins_by_the_apps_own_time(client, token):
    h = token("corrections:write")
    client.put("/v1/corrections/x1", json={"data": {"original": "a", "correction": "new"}, "updated_at": 200}, headers=h)
    r = client.put("/v1/corrections/x1", json={"data": {"original": "a", "correction": "old"}, "updated_at": 100}, headers=h)
    assert r.json()["data"]["correction"] == "new"


def test_paging(client, token):
    h = token("corrections:write")
    for i in range(5):
        client.post("/v1/corrections", json={"data": {"original": f"w{i}", "correction": "x"}}, headers=h)
    p = client.get("/v1/corrections?limit=2", headers=h).json()
    assert len(p["items"]) == 2 and p["more"]
    seen = [x["id"] for x in p["items"]]
    while p["more"]:
        p = client.get(f"/v1/corrections?limit=2&since={p['cursor']}", headers=h).json()
        seen += [x["id"] for x in p["items"]]
    assert len(set(seen)) == 5


def test_apply_is_whole_words_longest_first(client, token):
    h = token("corrections:write")
    for o, c in [("cleave its", "Clibbits"), ("cleave", "Cleve"), ("Abby", "Abi")]:
        client.post("/v1/corrections", json={"data": {"original": o, "correction": c}}, headers=h)
    r = client.post("/v1/corrections/apply", json={"text": "Abby opened cleave its, Abbyx, cleave"}, headers=h).json()
    assert r == {"text": "Abi opened Clibbits, Abbyx, Cleve", "count": 3}


def test_pairing_hands_the_token_over_once(client):
    assert client.post("/v1/pair", json={"app": "Clibbits", "scopes": ["nope:write"]}).status_code == 400
    p = client.post("/v1/pair", json={"app": "Clibbits", "scopes": ["corrections:write"]}).json()
    assert client.get(f"/v1/pair/{p['pairing_id']}").json() == {"status": "waiting"}
    auth.decide(p["code"].replace("-", "").lower(), True)
    got = client.get(f"/v1/pair/{p['pairing_id']}").json()
    assert got["status"] == "approved" and got["token"].startswith("ctr_")
    assert client.get(f"/v1/pair/{p['pairing_id']}").json() == {"status": "collected"}
    me = client.get("/v1/me", headers={"Authorization": f"Bearer {got['token']}"}).json()
    assert me["name"] == "Clibbits" and me["scopes"] == ["corrections:write"]


def test_the_owner_approves_over_the_api_and_can_revoke(client, token):
    owner = token("*")
    assert client.get("/v1/admin/pairings", headers=token("corrections:write")).status_code == 403
    p = client.post("/v1/pair", json={"app": "Herald", "scopes": ["corrections:read"]}).json()
    assert [x["code"] for x in client.get("/v1/admin/pairings", headers=owner).json()] == [p["code"]]
    client.post(f"/v1/admin/pairings/{p['pairing_id']}/approve", headers=owner)
    t = client.get(f"/v1/pair/{p['pairing_id']}").json()["token"]
    tid = client.get("/v1/me", headers={"Authorization": f"Bearer {t}"}).json()["id"]
    client.delete(f"/v1/admin/tokens/{tid}", headers=owner)
    assert client.get("/v1/me", headers={"Authorization": f"Bearer {t}"}).status_code == 401


def test_events_announce_each_change(client, token):
    import json, threading, time
    h = token("corrections:write")
    got = []

    def listen():
        with client.stream("GET", "/v1/events", headers=h) as s:
            for line in s.iter_lines():
                if line.startswith("data:"):
                    got.append(json.loads(line[5:]))
                    return

    t = threading.Thread(target=listen, daemon=True)
    t.start()
    time.sleep(0.5)
    client.post("/v1/corrections", json={"data": {"original": "a", "correction": "b"}}, headers=h)
    t.join(5)
    assert got and got[0]["schema"] == "corrections" and got[0]["deleted"] is False
