import SwiftUI

/// The two settings every app that speaks the protocol has (docs/protocol.md): one Center
/// server, and the other apps. Put it inside the app's Settings `Form`.
public struct CenterSettingsSections: View {
  @ObservedObject var network: CenterNetwork
  /// What this app does with the network, one line, e.g. "Corrections you make here go to
  /// Herald and your Center."
  let purpose: String
  @State private var centerDraft: String
  @State private var newApp = ""

  public init(network: CenterNetwork, purpose: String) {
    self.network = network
    self.purpose = purpose
    _centerDraft = State(initialValue: network.centerURL)
  }

  public var body: some View {
    Section {
      TextField("Address", text: $centerDraft, prompt: Text("http://my-server:8110"))
        .onSubmit { network.centerURL = centerDraft }
      if let center = network.center {
        NodeRow(node: center, network: network)
      }
    } header: {
      Text("Center server")
    } footer: {
      Text("Optional. A Center server you run shares data between all your apps and devices. While one is set, your apps share through it alone.")
        .font(.caption).foregroundStyle(.secondary)
    }
    Section {
      if network.usesCenter {
        Text("Your apps share through your Center server, so these direct connections aren't used.")
          .foregroundStyle(.secondary)
      } else if network.apps.isEmpty {
        Text("No other apps found on this Mac.").foregroundStyle(.secondary)
      }
      ForEach(network.apps) { node in
        NodeRow(node: node, network: network).disabled(network.usesCenter)
      }
      HStack {
        TextField("Add an app by address", text: $newApp, prompt: Text("http://other-mac.local:47110"))
          .onSubmit(addApp)
        Button("Add", action: addApp).disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    } header: {
      Text("Apps")
    } footer: {
      Text(purpose).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func addApp() {
    network.add(url: newApp)
    newApp = ""
  }
}

struct NodeRow: View {
  let node: CenterNetwork.Node
  @ObservedObject var network: CenterNetwork

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: node.kind == .center ? "server.rack" : "app.connected.to.app.below.fill")
        .foregroundStyle(node.paired ? Color.accentColor : .secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(node.name).lineLimit(1)
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer(minLength: 8)
      if node.paired {
        Button("Disconnect") { network.forget(node) }
      } else if node.status.hasPrefix("Approve") {
        ProgressView().controlSize(.small)
      } else if !node.schemas.isEmpty {
        Button("Connect") { network.connect(node) }
      }
      if node.kind == .added {
        Button(role: .destructive) { network.remove(node) } label: { Image(systemName: "minus.circle") }
          .buttonStyle(.borderless).help("Remove \(node.name)")
      }
    }
  }

  private var detail: String {
    if !node.status.isEmpty { return node.status }
    let what = node.schemas.isEmpty ? "serves nothing yet" : node.schemas.joined(separator: ", ")
    return node.paired ? "Connected · \(what)" : what
  }
}
