import Foundation
import Network

/// THE NODES THIS APP IS CONNECTED TO: the Center server set in Settings, and the other
/// apps that speak the protocol. Apps on this Mac are found over Bonjour (`_center._tcp`)
/// with no setup; others can be added by address. A node is used once it is paired.
///
/// THE CENTER OR THE APPS, NEVER BOTH (Joe, 2026-11-10: "A user of the system is probably
/// going to prefer that their information gets synced to the server if they have it
/// running ... App connections are for the people that don't have the server"). With a
/// Center server set, every write goes to it alone, and the other apps hear of it from
/// the Center. With none set, writes go to the paired apps.
///
/// Kept in UserDefaults: `center.url`, `center.apps` (addresses added by hand) and
/// `center.tokens` (a token per node: `app:<name>` for an app found over Bonjour, so a
/// port change does not lose it, the address otherwise).
@MainActor
public final class CenterNetwork: ObservableObject {
  public struct Node: Identifiable, Equatable {
    public enum Kind: Equatable { case center, discovered, added }
    public var name: String
    public var url: String
    public var kind: Kind
    public var schemas: [String]
    public var paired: Bool
    /// What is happening with it: "Approve code K7Q-2MX in Herald", "Can't reach it".
    public var status: String
    public var id: String { kind == .discovered ? "app:\(name)" : url }
    public func serves(_ schema: String) -> Bool { schemas.contains(schema) }
  }

  public let appName: String
  /// What this app asks a node for, e.g. ["corrections:write"]. A node is asked only for
  /// the schemas it serves.
  public let scopes: [String]

  @Published public private(set) var center: Node?
  @Published public private(set) var apps: [Node] = []
  @Published public var centerURL: String {
    didSet {
      guard centerURL != oldValue else { return }
      UserDefaults.standard.set(centerURL, forKey: Self.urlKey)
      Task { await refreshCenter() }
    }
  }

  static let urlKey = "center.url"
  static let appsKey = "center.apps"
  static let tokensKey = "center.tokens"

  private var discovered: [String: Node] = [:]
  private var added: [String: Node] = [:]
  private var browser: NWBrowser?
  private var watchers: [String: Task<Void, Never>] = [:]

  public init(appName: String, scopes: [String]) {
    self.appName = appName
    self.scopes = scopes
    self.centerURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
  }

  /// Start looking for apps on this Mac, and read what every node serves.
  public func start() {
    browse()
    Task { await refresh() }
  }

  public func refresh() async {
    await refreshCenter()
    for url in UserDefaults.standard.stringArray(forKey: Self.appsKey) ?? [] {
      await refreshAdded(url)
    }
  }

  // MARK: Using the nodes

  /// A client for a node, with its token.
  public func client(_ node: Node) -> CenterClient {
    CenterClient(base: node.url, token: token(for: node.id))
  }

  /// A Center server is set: the apps are not written to, even before it is paired.
  public var usesCenter: Bool { center != nil }

  /// The nodes a write to `schema` goes to: the Center server once it is paired, or, with
  /// no Center set, every paired app that serves `schema`.
  public func nodes(serving schema: String) -> [Node] {
    if let center { return center.paired && center.serves(schema) ? [center] : [] }
    return apps.filter { $0.paired && $0.serves(schema) }
  }

  /// The nodes a write would go to but which are not paired yet.
  public func unpaired(serving schema: String) -> [Node] {
    if let center { return !center.paired && center.serves(schema) ? [center] : [] }
    return apps.filter { !$0.paired && $0.serves(schema) }
  }

  /// WRITE TO THE NODES THAT TAKE THE SCHEMA (`nodes(serving:)`), by the record's own id,
  /// so a node that hears of it twice keeps one copy. Returns each node with what went wrong, if anything.
  /// An unpaired node is asked to pair, and the person approves it in that node's window.
  @discardableResult
  public func write<T: Codable>(_ schema: String, id: String, _ data: T) async -> [(Node, CenterError?)] {
    for node in unpaired(serving: schema) where node.status.isEmpty { connect(node) }
    var results: [(Node, CenterError?)] = []
    for node in nodes(serving: schema) {
      do {
        try await client(node).put(schema, id: id, data)
        results.append((node, nil))
      } catch let e as CenterError {
        if e.status == 401 { forget(node) }
        results.append((node, e))
      } catch {
        results.append((node, CenterError(error.localizedDescription)))
      }
    }
    return results
  }

  // MARK: Pairing

  /// Ask `node` to pair. Its status shows the code to approve there, then "Connected".
  public func connect(_ node: Node) {
    let wanted = scopes.filter { node.serves(String($0.split(separator: ":")[0])) }
    guard !wanted.isEmpty else { return setStatus(node, "\(node.name) serves nothing \(appName) uses.") }
    Task {
      do {
        let pairing = try await CenterClient(base: node.url).pair(app: appName, scopes: wanted)
        let place = node.kind == .center ? "on your Center server (center approve \(pairing.code))" : "in \(node.name)"
        setStatus(node, "Approve code \(pairing.code) \(place)")
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
          try await Task.sleep(nanoseconds: 1_500_000_000)
          let s = try await CenterClient(base: node.url).pairing(pairing.pairingId)
          switch s.status {
          case "approved":
            if let token = s.token { saveToken(token, for: node.id) }
            setStatus(node, "")
            return
          case "waiting":
            continue
          default:
            return setStatus(node, s.status == "denied" ? "\(node.name) said no." : "The request expired.")
          }
        }
        setStatus(node, "The request expired.")
      } catch {
        setStatus(node, error.localizedDescription)
      }
    }
  }

  /// Forget this node's token: it has to pair again.
  public func forget(_ node: Node) {
    var all = tokens
    all[node.id] = nil
    UserDefaults.standard.set(all, forKey: Self.tokensKey)
    update(node.id) { $0.paired = false }
  }

  /// Add an app by address (one on another Mac, or one Bonjour can't see).
  public func add(url: String) {
    let url = CenterClient(base: url).base
    guard !url.isEmpty else { return }
    var list = UserDefaults.standard.stringArray(forKey: Self.appsKey) ?? []
    if !list.contains(url) { list.append(url) }
    UserDefaults.standard.set(list, forKey: Self.appsKey)
    Task { await refreshAdded(url) }
  }

  public func remove(_ node: Node) {
    guard node.kind == .added else { return }
    forget(node)
    let list = (UserDefaults.standard.stringArray(forKey: Self.appsKey) ?? []).filter { $0 != node.url }
    UserDefaults.standard.set(list, forKey: Self.appsKey)
    added[node.url] = nil
    publish()
  }

  // MARK: Watching a node for changes

  /// Call `changed` whenever `node` announces a change to one of `schemas` (Center
  /// servers stream events; for an app it is a poll a minute). Reconnects on its own.
  public func watch(_ node: Node, _ schemas: [String], changed: @escaping @MainActor () -> Void) {
    watchers[node.id]?.cancel()
    watchers[node.id] = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, let client = Optional(self.client(node)) else { return }
        if node.kind == .center {
          do {
            for try await _ in client.events(schemas) { changed() }
          } catch {}
          try? await Task.sleep(nanoseconds: 5_000_000_000)
        } else {
          try? await Task.sleep(nanoseconds: 60_000_000_000)
          changed()
        }
      }
    }
  }

  public func unwatch(_ node: Node) {
    watchers[node.id]?.cancel()
    watchers[node.id] = nil
  }

  // MARK: Reading the nodes

  private func refreshCenter() async {
    let url = CenterClient(base: centerURL).base
    guard !url.isEmpty else {
      center = nil
      return
    }
    var node = Node(name: "Center", url: url, kind: .center, schemas: [], paired: false, status: "")
    do {
      let about = try await CenterClient(base: url).about()
      node.name = about.center
      node.schemas = about.schemas.keys.sorted()
    } catch {
      node.status = "Can't reach it."
    }
    node.paired = token(for: node.id) != nil
    if CenterClient(base: centerURL).base == url { center = node }
  }

  private func refreshAdded(_ url: String) async {
    var node = Node(name: url, url: url, kind: .added, schemas: [], paired: false, status: "")
    do {
      let about = try await CenterClient(base: url).about()
      node.name = about.app ?? about.center
      node.schemas = about.schemas.keys.sorted()
    } catch {
      node.status = "Can't reach it."
    }
    node.paired = token(for: node.id) != nil
    added[url] = node
    publish()
  }

  private func browse() {
    guard browser == nil else { return }
    let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_center._tcp", domain: nil), using: .tcp)
    b.browseResultsChangedHandler = { [weak self] results, _ in
      Task { @MainActor in self?.found(results) }
    }
    b.start(queue: .main)
    browser = b
  }

  private func found(_ results: Set<NWBrowser.Result>) {
    var now: [String: Node] = [:]
    for result in results {
      guard case .bonjour(let txt) = result.metadata, let app = txt["app"], app != appName,
        let port = txt["port"], txt["host"] == CenterLocalNode.hostName
      else { continue }
      let schemas = (txt["schemas"] ?? "").split(separator: ",").map(String.init)
      var node = Node(name: app, url: "http://127.0.0.1:\(port)", kind: .discovered, schemas: schemas,
                      paired: false, status: discovered["app:\(app)"]?.status ?? "")
      node.paired = token(for: node.id) != nil
      now[node.id] = node
    }
    discovered = now
    publish()
  }

  private func publish() {
    apps = (Array(discovered.values) + Array(added.values)).sorted { $0.name < $1.name }
  }

  private func setStatus(_ node: Node, _ status: String) {
    update(node.id) {
      $0.status = status
      $0.paired = self.token(for: node.id) != nil
    }
  }

  private func update(_ id: String, _ change: (inout Node) -> Void) {
    if var c = center, c.id == id {
      change(&c)
      center = c
    }
    if var n = discovered[id] {
      change(&n)
      discovered[id] = n
    }
    if let key = added.first(where: { $0.value.id == id })?.key, var n = added[key] {
      change(&n)
      added[key] = n
    }
    publish()
  }

  private var tokens: [String: String] {
    UserDefaults.standard.dictionary(forKey: Self.tokensKey) as? [String: String] ?? [:]
  }

  private func token(for id: String) -> String? { tokens[id] }

  private func saveToken(_ token: String, for id: String) {
    var all = tokens
    all[id] = token
    UserDefaults.standard.set(all, forKey: Self.tokensKey)
  }
}
