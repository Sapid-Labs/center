import CryptoKit
import Foundation
import Network

/// One stored record, as a schema provider hands it to the local node.
public struct CenterRawRecord {
  public let id: String
  public let data: [String: Any]
  public let createdAt: Double
  public let updatedAt: Double
  public let deleted: Bool
  public let seq: Int

  public init(id: String, data: [String: Any], createdAt: Double, updatedAt: Double, deleted: Bool = false, seq: Int) {
    self.id = id
    self.data = data
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deleted = deleted
    self.seq = seq
  }

  var json: [String: Any] {
    ["id": id, "data": data, "created_at": createdAt, "updated_at": updatedAt, "deleted": deleted, "seq": seq]
  }
}

/// A schema an app serves from its local node. Called on the main thread.
public protocol CenterSchemaProvider: AnyObject {
  var version: Int { get }
  var description: String { get }
  /// Records changed after `since` (a cursor this provider gave out), oldest first.
  func changes(since: Int) -> [CenterRawRecord]
  func get(_ id: String) -> CenterRawRecord?
  /// Add or replace by id. `updatedAt` is the writer's time; an older write is ignored.
  /// Throws a `CenterError` with status 400 for data that is not the schema's.
  func put(_ id: String, data: [String: Any], updatedAt: Double?) throws -> CenterRawRecord
  /// Add with no id: the provider merges it into a record with the same natural key.
  func add(data: [String: Any], updatedAt: Double?) throws -> CenterRawRecord
  func delete(_ id: String, updatedAt: Double?) -> CenterRawRecord?
}

/// THE APP'S OWN NODE: the Center protocol for the schemas this app owns, served on
/// 127.0.0.1 and advertised over Bonjour as `_center._tcp`, so other apps on this Mac
/// find it with no setup (docs/protocol.md).
///
/// Pairing asks the person in this app's own window (`approve`). Tokens are kept as
/// hashes in UserDefaults (`center.node.tokens`).
public final class CenterLocalNode {
  public let appName: String
  public let version: String
  public private(set) var port: UInt16?
  public var providers: [String: CenterSchemaProvider]
  /// Ask the person whether `app` may have `scopes`; `code` is the one the app shows.
  public var approve: (_ app: String, _ scopes: [String], _ code: String, _ done: @escaping (Bool) -> Void) -> Void

  private var listener: NWListener?
  private let preferredPort: UInt16
  private var pairings: [String: Pairing] = [:]
  private static let tokensKey = "center.node.tokens"
  private static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

  struct Pairing {
    let code: String
    let app: String
    let scopes: [String]
    let created: Date
    var status: String
    var token: String?
  }

  public init(
    appName: String, version: String, preferredPort: UInt16, providers: [String: CenterSchemaProvider],
    approve: @escaping (String, [String], String, @escaping (Bool) -> Void) -> Void
  ) {
    self.appName = appName
    self.version = version
    self.preferredPort = preferredPort
    self.providers = providers
    self.approve = approve
  }

  /// Listen on the preferred port, or the next free one of the twenty after it. The
  /// port is in the Bonjour TXT record, so it must be known before the listener starts.
  public func start() {
    guard listener == nil else { return }
    listen(on: preferredPort)
  }

  private func listen(on port: UInt16) {
    guard port < preferredPort &+ 20, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
    guard let l = try? NWListener(using: params) else { return listen(on: port + 1) }
    var txt = NWTXTRecord()
    txt["app"] = appName
    txt["port"] = "\(port)"
    txt["host"] = CenterLocalNode.hostName
    txt["schemas"] = providers.keys.sorted().joined(separator: ",")
    txt["api"] = "\(centerAPI)"
    l.service = NWListener.Service(name: appName, type: "_center._tcp", domain: nil, txtRecord: txt)
    l.newConnectionHandler = { [weak self] c in self?.serve(c) }
    l.stateUpdateHandler = { [weak self, weak l] state in
      guard let self, let l, self.listener === l else { return }
      switch state {
      case .ready:
        self.port = port
      case .failed:
        // Taken: the next port.
        l.cancel()
        self.listener = nil
        self.port = nil
        self.listen(on: port + 1)
      default:
        break
      }
    }
    listener = l
    l.start(queue: .main)
  }

  public func stop() {
    listener?.cancel()
    listener = nil
  }

  /// This Mac's name as Bonjour peers compare it: a node advertised from the same host is
  /// reached on 127.0.0.1.
  public static var hostName: String { ProcessInfo.processInfo.hostName.lowercased() }

  // MARK: Connections

  private func serve(_ c: NWConnection) {
    c.start(queue: .main)
    var buffer = Data()
    func read() {
      c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
        guard let self else { return c.cancel() }
        if let data { buffer += data }
        do {
          if let request = try HTTPRequest.parse(buffer) {
            let response = self.handle(request)
            c.send(content: response.bytes, completion: .contentProcessed { _ in c.cancel() })
          } else if done || error != nil {
            c.cancel()
          } else {
            read()
          }
        } catch let e as CenterError {
          c.send(content: HTTPResponse.error(e.status, e.message).bytes, completion: .contentProcessed { _ in c.cancel() })
        } catch {
          c.cancel()
        }
      }
    }
    read()
  }

  // MARK: Routes

  func handle(_ r: HTTPRequest) -> HTTPResponse {
    let parts = r.path.split(separator: "/").map(String.init)
    guard parts.first == "v1" else { return .error(404, "Not a Center call.") }
    let rest = Array(parts.dropFirst())
    if rest.isEmpty, r.method == "GET" { return .json(200, aboutJSON) }
    if rest == ["pair"], r.method == "POST" { return startPairing(r.json()) }
    if rest.count == 2, rest[0] == "pair", r.method == "GET" { return collect(rest[1]) }
    if rest == ["me"], r.method == "GET" {
      guard let who = caller(r) else { return .error(401, "Pair this app with \(appName) first.") }
      return .json(200, ["name": who.name, "scopes": who.scopes])
    }
    if let schema = rest.first, providers[schema] != nil, rest.count <= 2 {
      return schemaCall(r, schema, rest.count > 1 ? rest[1] : nil)
    }
    return .error(404, "\(appName) has no such call.")
  }

  var aboutJSON: [String: Any] {
    var schemas: [String: Any] = [:]
    for (name, p) in providers { schemas[name] = ["version": p.version, "description": p.description] }
    return ["center": appName, "app": appName, "version": version, "api": centerAPI, "schemas": schemas]
  }

  private func schemaCall(_ r: HTTPRequest, _ schema: String, _ id: String?) -> HTTPResponse {
    guard let p = providers[schema] else { return .error(404, "No schema \(schema).") }
    guard let who = caller(r) else { return .error(401, "Pair this app with \(appName) first.") }
    let reading = r.method == "GET"
    guard CenterLocalNode.allows(who.scopes, "\(schema):\(reading ? "read" : "write")") else {
      return .error(403, "This app's token does not allow \(schema):\(reading ? "read" : "write").")
    }
    let body = r.json()
    let at = (body?["updated_at"] as? Double) ?? r.query["updated_at"].flatMap(Double.init)
    do {
      switch (r.method, id) {
      case ("GET", nil):
        let since = Int(r.query["since"] ?? "0") ?? 0
        let items = p.changes(since: since)
        return .json(200, ["items": items.map(\.json), "cursor": items.last?.seq ?? since, "more": false])
      case ("GET", let id?):
        guard let rec = p.get(id) else { return .error(404, "No such \(schema) record.") }
        return .json(200, rec.json)
      case ("POST", nil):
        guard let data = body?["data"] as? [String: Any] else { return .error(400, "The body needs data.") }
        return .json(200, try p.add(data: data, updatedAt: at).json)
      case ("PUT", let id?):
        guard let data = body?["data"] as? [String: Any] else { return .error(400, "The body needs data.") }
        return .json(200, try p.put(id, data: data, updatedAt: at).json)
      case ("DELETE", let id?):
        guard let rec = p.delete(id, updatedAt: at) else { return .error(404, "No such \(schema) record.") }
        return .json(200, rec.json)
      default:
        return .error(405, "Not a \(schema) call.")
      }
    } catch let e as CenterError {
      return .error(e.status == 0 ? 400 : e.status, e.message)
    } catch {
      return .error(400, error.localizedDescription)
    }
  }

  // MARK: Pairing and tokens

  private func startPairing(_ body: [String: Any]?) -> HTTPResponse {
    guard let app = (body?["app"] as? String)?.trimmingCharacters(in: .whitespaces), !app.isEmpty,
      let scopes = body?["scopes"] as? [String], !scopes.isEmpty
    else { return .error(400, "Send the app's name and the scopes it wants.") }
    for s in scopes {
      let bits = s.split(separator: ":").map(String.init)
      guard bits.count == 2, providers[bits[0]] != nil, ["read", "write"].contains(bits[1]) else {
        return .error(400, "\(appName) has no scope \(s).")
      }
    }
    pairings = pairings.filter { $0.value.created.timeIntervalSinceNow > -600 }
    guard pairings.values.filter({ $0.status == "waiting" }).count < 5 else {
      return .error(429, "Too many pairing requests are waiting.")
    }
    let id = UUID().uuidString.lowercased()
    let raw = String((0..<6).map { _ in CenterLocalNode.alphabet.randomElement()! })
    let code = "\(raw.prefix(3))-\(raw.suffix(3))"
    pairings[id] = Pairing(code: code, app: app, scopes: scopes, created: Date(), status: "waiting")
    approve(app, scopes, code) { [weak self] yes in
      guard let self, var p = self.pairings[id], p.status == "waiting" else { return }
      p.status = yes ? "approved" : "denied"
      if yes { p.token = self.issue(name: app, scopes: scopes) }
      self.pairings[id] = p
    }
    return .json(200, ["pairing_id": id, "code": code, "expires_in": 600])
  }

  private func collect(_ id: String) -> HTTPResponse {
    guard var p = pairings[id] else { return .error(404, "No such pairing request.") }
    if p.status == "waiting", p.created.timeIntervalSinceNow < -600 { return .json(200, ["status": "expired"]) }
    if p.status == "approved", let token = p.token {
      p.status = "collected"
      p.token = nil
      pairings[id] = p
      return .json(200, ["status": "approved", "token": token])
    }
    return .json(200, ["status": p.status])
  }

  struct Grant: Codable {
    let hash: String
    let name: String
    let scopes: [String]
  }

  static func grants() -> [Grant] {
    guard let data = UserDefaults.standard.data(forKey: tokensKey) else { return [] }
    return (try? JSONDecoder().decode([Grant].self, from: data)) ?? []
  }

  /// The apps this node has paired with, for Settings.
  public static func pairedApps() -> [(name: String, scopes: [String])] {
    grants().map { ($0.name, $0.scopes) }
  }

  /// Forget an app's tokens: it has to pair again.
  public static func forget(app: String) {
    let kept = grants().filter { $0.name != app }
    UserDefaults.standard.set(try? JSONEncoder().encode(kept), forKey: tokensKey)
  }

  private func issue(name: String, scopes: [String]) -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let token = "ctr_" + Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let all = CenterLocalNode.grants() + [Grant(hash: CenterLocalNode.hash(token), name: name, scopes: scopes)]
    UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: CenterLocalNode.tokensKey)
    return token
  }

  private func caller(_ r: HTTPRequest) -> Grant? {
    guard let token = r.bearer else { return nil }
    let h = CenterLocalNode.hash(token)
    return CenterLocalNode.grants().first { $0.hash == h }
  }

  static func hash(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func allows(_ scopes: [String], _ need: String) -> Bool {
    if scopes.contains("*") || scopes.contains(need) { return true }
    let bits = need.split(separator: ":")
    return bits.count == 2 && bits[1] == "read" && scopes.contains("\(bits[0]):write")
  }
}
