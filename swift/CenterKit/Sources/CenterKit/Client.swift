import Foundation

/// The calls one node answers. Every call is to `base` (no trailing slash) with `token`.
public struct CenterClient {
  public let base: String
  public var token: String?

  public init(base: String, token: String? = nil) {
    var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while b.hasSuffix("/") { b.removeLast() }
    self.base = b
    self.token = token
  }

  public struct Pairing: Codable, Equatable {
    public let pairingId: String
    public let code: String
    enum CodingKeys: String, CodingKey {
      case code
      case pairingId = "pairing_id"
    }
  }

  public struct PairingStatus: Codable, Equatable {
    /// waiting, approved, denied, collected or expired.
    public let status: String
    public let token: String?
  }

  /// A change announced on `GET /v1/events`.
  public struct Event: Codable, Equatable {
    public let schema: String
    public let id: String
    public let seq: Int
    public let deleted: Bool
  }

  public func about() async throws -> CenterAbout {
    try await call("GET", "/v1", timeout: 5)
  }

  public func pair(app: String, scopes: [String]) async throws -> Pairing {
    try await call("POST", "/v1/pair", body: ["app": app, "scopes": scopes])
  }

  public func pairing(_ id: String) async throws -> PairingStatus {
    try await call("GET", "/v1/pair/\(id)")
  }

  public func changes<T: Codable>(_ schema: String, since: Int, as: T.Type = T.self) async throws -> CenterPage<T> {
    try await call("GET", "/v1/\(schema)?since=\(since)&limit=1000")
  }

  /// Everything since `since`, page after page.
  public func allChanges<T: Codable>(_ schema: String, since: Int, as: T.Type = T.self) async throws
    -> (items: [CenterRecord<T>], cursor: Int)
  {
    var items: [CenterRecord<T>] = []
    var cursor = since
    while true {
      let page: CenterPage<T> = try await changes(schema, since: cursor)
      items += page.items
      cursor = page.cursor
      if !page.more { return (items, cursor) }
    }
  }

  @discardableResult
  public func put<T: Codable>(_ schema: String, id: String, _ data: T, updatedAt: Date = Date()) async throws
    -> CenterRecord<T>
  {
    try await call(
      "PUT", "/v1/\(schema)/\(id)",
      body: ["data": try JSONSerialization.jsonObject(with: JSONEncoder().encode(data)),
             "updated_at": updatedAt.timeIntervalSince1970])
  }

  @discardableResult
  public func add<T: Codable>(_ schema: String, _ data: T, updatedAt: Date = Date()) async throws -> CenterRecord<T> {
    try await call(
      "POST", "/v1/\(schema)",
      body: ["data": try JSONSerialization.jsonObject(with: JSONEncoder().encode(data)),
             "updated_at": updatedAt.timeIntervalSince1970])
  }

  public func delete(_ schema: String, id: String, updatedAt: Date = Date()) async throws {
    let _: CenterRecord<CorrectionData>? = try? await call(
      "DELETE", "/v1/\(schema)/\(id)?updated_at=\(updatedAt.timeIntervalSince1970)")
  }

  /// The node's change stream. Ends when the connection does; the caller reconnects.
  public func events(_ schemas: [String]) -> AsyncThrowingStream<Event, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let r = try request("GET", "/v1/events?schemas=\(schemas.joined(separator: ","))", timeout: 3600)
          let (bytes, response) = try await URLSession.shared.bytes(for: r)
          let code = (response as? HTTPURLResponse)?.statusCode ?? 0
          guard code == 200 else { throw CenterError("The events stream answered \(code).", status: code) }
          for try await line in bytes.lines where line.hasPrefix("data:") {
            if let event = try? JSONDecoder().decode(Event.self, from: Data(line.dropFirst(5).utf8)) {
              continuation.yield(event)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: The plumbing

  func request(_ method: String, _ path: String, body: Any? = nil, timeout: TimeInterval = 10) throws -> URLRequest {
    guard let url = URL(string: base + path), url.scheme != nil else {
      throw CenterError("\(base) is not an address.")
    }
    var r = URLRequest(url: url, timeoutInterval: timeout)
    r.httpMethod = method
    if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      r.setValue("application/json", forHTTPHeaderField: "Content-Type")
      r.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    return r
  }

  func call<T: Decodable>(_ method: String, _ path: String, body: Any? = nil, timeout: TimeInterval = 10)
    async throws -> T
  {
    let r = try request(method, path, body: body, timeout: timeout)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: r)
    } catch {
      throw CenterError("Couldn't reach \(base).")
    }
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else {
      let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"]
      throw CenterError((detail as? String) ?? "\(base) answered \(code).", status: code)
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw CenterError("\(base) sent something CenterKit can't read.", status: code)
    }
  }
}
