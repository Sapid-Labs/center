import Foundation

/// The protocol version this CenterKit speaks (`api` in `GET /v1`).
public let centerAPI = 1

/// The schemas CenterKit knows. Their shapes match `server/center/schemas/`.
public enum CenterSchema {
  public static let corrections = "corrections"
}

/// `GET /v1`: what a node is and which schemas it serves.
public struct CenterAbout: Codable, Equatable {
  public struct Schema: Codable, Equatable {
    public let version: Int
    public let description: String
  }
  /// The node's name: the Center's own, or the app's.
  public let center: String
  /// Set when the node is an app rather than a Center server.
  public let app: String?
  public let version: String
  public let api: Int
  public let schemas: [String: Schema]

  public init(center: String, app: String?, version: String, schemas: [String: Schema]) {
    self.center = center
    self.app = app
    self.version = version
    self.api = centerAPI
    self.schemas = schemas
  }

  public func serves(_ schema: String) -> Bool { schemas[schema] != nil }
}

/// One record of a schema whose data is `T`.
public struct CenterRecord<T: Codable>: Codable {
  public let id: String
  public let data: T?
  public let createdAt: Double
  public let updatedAt: Double
  public let deleted: Bool
  public let seq: Int

  enum CodingKeys: String, CodingKey {
    case id, data, deleted, seq
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  public init(id: String, data: T?, createdAt: Double, updatedAt: Double, deleted: Bool, seq: Int) {
    self.id = id
    self.data = data
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deleted = deleted
    self.seq = seq
  }
}

/// `GET /v1/<schema>?since=`: the changes, and the cursor to send next time.
public struct CenterPage<T: Codable>: Codable {
  public let items: [CenterRecord<T>]
  public let cursor: Int
  public let more: Bool
}

/// A transcription correction: "heard `original`, meant `correction`".
public struct CorrectionData: Codable, Equatable {
  public var original: String
  public var correction: String
  public var enabled: Bool
  /// The app the correction came from.
  public var source: String?

  public init(original: String, correction: String, enabled: Bool = true, source: String? = nil) {
    self.original = original
    self.correction = correction
    self.enabled = enabled
    self.source = source
  }

  /// The natural key: one correction per phrase, case ignored.
  public var key: String { original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}

/// What a node said went wrong, in its own words where it gave them.
public struct CenterError: LocalizedError, Equatable {
  public let message: String
  public let status: Int
  public init(_ message: String, status: Int = 0) {
    self.message = message
    self.status = status
  }
  public var errorDescription: String? { message }
}
