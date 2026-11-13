import Foundation
import Network
import HubCore

/// A tiny web server that only this phone can reach (127.0.0.1), so another app on the phone can hand
/// Glasses Hub text to show. It runs while Glasses Hub is running, which with the display on includes
/// the background.
final class LocalAPI: @unchecked Sendable {
    static let defaultPort: UInt16 = 8765
    private let queue = DispatchQueue(label: "glasseshub.localapi")
    private var listener: NWListener?
    /// Answers a request with the JSON to send back and its status. Called off the main thread.
    var handler: (@Sendable (LocalRequest) async -> (Int, [String: Any]))?
    var onState: (@Sendable (String) -> Void)?

    func start(port: UInt16) {
        stop()
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? 8765)
        guard let made = try? NWListener(using: parameters) else { onState?("Couldn't open port \(port)."); return }
        made.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        made.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState?("Listening on port \(port).")
            case .failed(let error): self?.onState?("Stopped: \(error.localizedDescription)")
            case .cancelled: self?.onState?("Off.")
            default: break
            }
        }
        made.start(queue: queue)
        listener = made
    }

    func stop() {
        listener?.cancel(); listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, so: Data())
    }

    private func read(_ connection: NWConnection, so far: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var all = far
            if let data { all.append(data) }
            if let request = LocalRequest.parse(all) {
                let handler = self.handler
                Task {
                    let (status, json) = await handler?(request) ?? (404, ["ok": false])
                    connection.send(content: LocalRequest.response(status: status, json: json), completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if done || error != nil || all.count > 262_144 {
                connection.cancel()
            } else {
                self.read(connection, so: all)
            }
        }
    }
}
