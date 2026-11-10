import XCTest

@testable import CenterKit

final class Store: CenterSchemaProvider {
  var rows: [String: CenterRawRecord] = [:]
  var seq = 0
  let version = 1
  let description = "test"
  func changes(since: Int) -> [CenterRawRecord] { rows.values.filter { $0.seq > since }.sorted { $0.seq < $1.seq } }
  func get(_ id: String) -> CenterRawRecord? { rows[id] }
  func put(_ id: String, data: [String: Any], updatedAt: Double?) throws -> CenterRawRecord {
    guard data["original"] is String else { throw CenterError("original is missing", status: 400) }
    seq += 1
    let r = CenterRawRecord(id: id, data: data, createdAt: 1, updatedAt: updatedAt ?? 2, seq: seq)
    rows[id] = r
    return r
  }
  func add(data: [String: Any], updatedAt: Double?) throws -> CenterRawRecord {
    try put(UUID().uuidString, data: data, updatedAt: updatedAt)
  }
  func delete(_ id: String, updatedAt: Double?) -> CenterRawRecord? { rows.removeValue(forKey: id) }
}

final class CenterKitTests: XCTestCase {
  override func setUp() {
    UserDefaults.standard.removeObject(forKey: "center.node.tokens")
  }

  func testARequestIsParsedOnlyOnceItIsWhole() throws {
    let head = "PUT /v1/corrections/x1?since=4 HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\n"
    XCTAssertNil(try HTTPRequest.parse(Data(head.utf8)))
    let r = try XCTUnwrap(HTTPRequest.parse(Data((head + "{\"a\": true}").utf8)))
    XCTAssertEqual(r.method, "PUT")
    XCTAssertEqual(r.path, "/v1/corrections/x1")
    XCTAssertEqual(r.query["since"], "4")
    XCTAssertEqual(r.json()?["a"] as? Bool, true)
  }

  func node(approving: Bool = true) -> (CenterLocalNode, Store) {
    let store = Store()
    let node = CenterLocalNode(
      appName: "Herald", version: "1", preferredPort: 47999, providers: ["corrections": store]
    ) { _, _, _, done in done(approving) }
    return (node, store)
  }

  func call(_ node: CenterLocalNode, _ method: String, _ path: String, token: String? = nil, body: Any? = nil)
    -> (Int, [String: Any])
  {
    var raw = "\(method) \(path) HTTP/1.1\r\n"
    if let token { raw += "Authorization: Bearer \(token)\r\n" }
    let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
    raw += "Content-Length: \(data.count)\r\n\r\n"
    let r = try! HTTPRequest.parse(Data(raw.utf8) + data)!
    let res = node.handle(r)
    return (res.status, (try? JSONSerialization.jsonObject(with: res.body)) as? [String: Any] ?? [:])
  }

  func pair(_ node: CenterLocalNode, _ scopes: [String]) -> String? {
    let (_, p) = call(node, "POST", "/v1/pair", body: ["app": "Clibbits", "scopes": scopes])
    return call(node, "GET", "/v1/pair/\(p["pairing_id"] as! String)").1["token"] as? String
  }

  func testAboutNamesTheAppAndItsSchemas() {
    let (n, _) = node()
    let (code, about) = call(n, "GET", "/v1")
    XCTAssertEqual(code, 200)
    XCTAssertEqual(about["app"] as? String, "Herald")
    XCTAssertNotNil((about["schemas"] as? [String: Any])?["corrections"])
  }

  func testAPairedAppWritesAndAnUnpairedOneCannot() {
    let (n, store) = node()
    let body: [String: Any] = ["data": ["original": "Abby", "correction": "Abi", "enabled": true]]
    XCTAssertEqual(call(n, "PUT", "/v1/corrections/x1", body: body).0, 401)
    let token = pair(n, ["corrections:write"])
    XCTAssertNotNil(token)
    XCTAssertEqual(call(n, "PUT", "/v1/corrections/x1", token: token, body: body).0, 200)
    XCTAssertEqual(store.rows["x1"]?.data["correction"] as? String, "Abi")
    // Write covers read.
    let (code, page) = call(n, "GET", "/v1/corrections?since=0", token: token)
    XCTAssertEqual(code, 200)
    XCTAssertEqual((page["items"] as? [Any])?.count, 1)
    XCTAssertEqual(call(n, "PUT", "/v1/corrections/x2", token: token, body: ["data": ["nope": 1]]).0, 400)
  }

  func testAReadOnlyTokenCannotWriteAndARefusedPairingGetsNoToken() {
    let (n, _) = node()
    let token = pair(n, ["corrections:read"])
    XCTAssertEqual(call(n, "PUT", "/v1/corrections/x1", token: token, body: ["data": ["original": "a"]]).0, 403)
    let (no, _) = node(approving: false)
    XCTAssertNil(pair(no, ["corrections:write"]))
    XCTAssertEqual(call(no, "POST", "/v1/pair", body: ["app": "X", "scopes": ["notes:write"]]).0, 400)
  }

  func testTheTokenIsHandedOverOnce() {
    let (n, _) = node()
    let (_, p) = call(n, "POST", "/v1/pair", body: ["app": "Clibbits", "scopes": ["corrections:write"]])
    let id = p["pairing_id"] as! String
    XCTAssertNotNil(call(n, "GET", "/v1/pair/\(id)").1["token"])
    XCTAssertEqual(call(n, "GET", "/v1/pair/\(id)").1["status"] as? String, "collected")
    XCTAssertEqual(CenterLocalNode.pairedApps().map(\.name), ["Clibbits"])
  }

  func testRecordsDecodeFromTheServersJSON() throws {
    let json = """
      {"items":[{"id":"a","data":{"original":"chunky","correction":"Chonky","enabled":true,"source":"herald"},
      "created_at":1,"updated_at":2,"deleted":false,"seq":7}],"cursor":7,"more":false}
      """
    let page = try JSONDecoder().decode(CenterPage<CorrectionData>.self, from: Data(json.utf8))
    XCTAssertEqual(page.items[0].data?.correction, "Chonky")
    XCTAssertEqual(page.cursor, 7)
  }

  @MainActor
  func testOverTheNetworkAnAppPairsAndWrites() async throws {
    let (n, store) = node()
    n.start()
    for _ in 0..<50 where n.port == nil { try await Task.sleep(nanoseconds: 100_000_000) }
    let port = try XCTUnwrap(n.port)
    var client = CenterClient(base: "http://127.0.0.1:\(port)")
    let about = try await client.about()
    XCTAssertEqual(about.app, "Herald")
    XCTAssertTrue(about.serves("corrections"))
    let pairing = try await client.pair(app: "Clibbits", scopes: ["corrections:write"])
    client.token = try await client.pairing(pairing.pairingId).token
    try await client.put("corrections", id: "x1", CorrectionData(original: "Abby", correction: "Abi"))
    XCTAssertEqual(store.rows["x1"]?.data["correction"] as? String, "Abi")
    let page: CenterPage<CorrectionData> = try await client.changes("corrections", since: 0)
    XCTAssertEqual(page.items.first?.data?.original, "Abby")
    n.stop()
  }

  @MainActor
  func testWithACenterSetTheAppsAreNotWrittenTo() {
    UserDefaults.standard.removeObject(forKey: "center.url")
    let net = CenterNetwork(appName: "Test", scopes: ["corrections:write"])
    XCTAssertFalse(net.usesCenter)
    XCTAssertTrue(net.nodes(serving: "corrections").isEmpty)
  }
}
