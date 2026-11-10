import Foundation

/// The little HTTP/1.1 the local node needs: one request per connection, a JSON body.
struct HTTPRequest: Equatable {
  let method: String
  let path: String
  let query: [String: String]
  let headers: [String: String]
  let body: Data

  /// Parses `data` when it holds a whole request: nil while more is still to come.
  /// Throws on something that is not HTTP.
  static func parse(_ data: Data) throws -> HTTPRequest? {
    guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
      if data.count > 64 * 1024 { throw CenterError("Headers too long", status: 431) }
      return nil
    }
    guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else {
      throw CenterError("Not HTTP", status: 400)
    }
    var lines = head.components(separatedBy: "\r\n")
    let first = lines.removeFirst().split(separator: " ")
    guard first.count >= 2 else { throw CenterError("Not HTTP", status: 400) }
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let length = Int(headers["content-length"] ?? "0") ?? 0
    if length > 1024 * 1024 { throw CenterError("Body too large", status: 413) }
    let bodyStart = end.upperBound
    guard data.count - bodyStart >= length else { return nil }
    let target = String(first[1])
    let parts = URLComponents(string: target)
    var query: [String: String] = [:]
    for item in parts?.queryItems ?? [] { query[item.name] = item.value ?? "" }
    return HTTPRequest(
      method: String(first[0]).uppercased(), path: parts?.path ?? target, query: query, headers: headers,
      body: data.subdata(in: bodyStart..<(bodyStart + length)))
  }

  var bearer: String? {
    guard let h = headers["authorization"], h.lowercased().hasPrefix("bearer ") else { return query["token"] }
    return String(h.dropFirst(7)).trimmingCharacters(in: .whitespaces)
  }

  func json() -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
  }
}

struct HTTPResponse {
  let status: Int
  let body: Data

  static func json(_ status: Int, _ object: Any) -> HTTPResponse {
    HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
  }

  static func error(_ status: Int, _ detail: String) -> HTTPResponse { json(status, ["detail": detail]) }

  var bytes: Data {
    let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                  405: "Method Not Allowed", 413: "Payload Too Large", 429: "Too Many Requests"][status] ?? "Error"
    var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\n"
    head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    return Data(head.utf8) + body
  }
}
