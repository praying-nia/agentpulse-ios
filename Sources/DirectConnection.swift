import CryptoKit
import Foundation
import Network
import Security

enum PulseError: LocalizedError {
    case invalidQR, expired, unsupportedRoute, invalidReply, keychain(OSStatus), host(String)

    var errorDescription: String? {
        switch self {
        case .invalidQR: "Choose an image containing one valid AgentPulse pairing QR code."
        case .expired: "The pairing QR code expired. Generate a new code on the Host."
        case .unsupportedRoute: "This client requires a direct pairing QR code (v2)."
        case .invalidReply: "The Host returned an unexpected protocol message."
        case .keychain(let status): "Keychain error (\(status))."
        case .host(let message): message
        }
    }
}

let wireDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}()

func uuidV7() -> String {
    var bytes = withUnsafeBytes(of: UUID().uuid) { Array($0) }
    let milliseconds = UInt64(Date().timeIntervalSince1970 * 1_000)
    for index in 0..<6 {
        bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> ((5 - index) * 8))
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x70
    let hex = bytes.map { String(format: "%02x", $0) }
    return [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]]
        .map { $0.joined() }.joined(separator: "-")
}

private func validUUID(_ value: String) -> Bool {
    guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else { return false }
    return uuid.uuid.6 >> 4 == 7 && uuid.uuid.8 >> 6 == 2
}

private func validAddress(_ value: String) -> Bool {
    if let address = IPv4Address(value) { return address != .any && !address.isMulticast && address.rawValue != Data(repeating: 255, count: 4) }
    if let address = IPv6Address(value), !value.contains("%") { return address != .any && !address.isMulticast }
    let labels = value.split(separator: ".", omittingEmptySubsequences: false)
    return value.utf8.count <= 253 && !labels.isEmpty && labels.allSatisfy { label in
        !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
        label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
    }
}

struct PairingBundle: Decodable {
    let pairingVersion: Int
    let pairingId: String
    let hostId: String
    let hostName: String
    let serverName: String
    let address: String
    let port: UInt16
    let leafSha256: String
    let bootstrapToken: String
    let route: String
    let expiresAtUnixSeconds: Int64

    static func parse(_ uri: String, now: Date = .now) throws -> Self {
        if uri.hasPrefix("agentpulse://pair/v1/") { throw PulseError.unsupportedRoute }
        let prefix = "agentpulse://pair/v2/"
        guard uri.hasPrefix(prefix), uri.utf8.count <= 4_096 else { throw PulseError.invalidQR }
        let encoded = String(uri.dropFirst(prefix.count))
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        guard !encoded.isEmpty, encoded.allSatisfy({ alphabet.contains($0) }) else { throw PulseError.invalidQR }
        let standard = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              data.base64EncodedString() == padded,
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(fields.keys) == ["pairing_version", "pairing_id", "host_id", "host_name", "server_name",
                                  "address", "port", "leaf_sha256", "bootstrap_token", "route", "expires_at_unix_seconds"],
              let qr = try? wireDecoder.decode(Self.self, from: data),
              qr.pairingVersion == 2, qr.route == "direct", qr.port > 0,
              validUUID(qr.pairingId), validUUID(qr.hostId),
              qr.serverName == "\(qr.hostId).agentpulse.local",
              !qr.hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              validAddress(qr.address), !qr.bootstrapToken.isEmpty,
              qr.leafSha256.utf8.count == 64,
              qr.leafSha256.allSatisfy({ "0123456789abcdef".contains($0) })
        else { throw PulseError.invalidQR }
        guard Double(qr.expiresAtUnixSeconds) > now.timeIntervalSince1970 else { throw PulseError.expired }
        return qr
    }
}

struct HostCredential: Codable {
    let hostId: String
    let hostName: String
    let serverName: String
    let address: String
    let port: UInt16
    let certificate: Data
    let token: String
    let clientId: String

    private struct Reply: Decodable {
        let type: String
        let clientId: String?
        let hostId: String?
        let hostName: String?
        let serverName: String?
        let nativeAddress: String?
        let nativePort: UInt16?
        let caCertificateDer: String?
        let accessToken: String?
        let nativeTransportVersion: Int?
        let domainProtocolVersions: [Int]?
        let message: String?
    }

    @MainActor
    static func pair(using qr: PairingBundle, clientId: String, displayName: String) async throws -> Self {
        let socket = try PulseSocket(
            address: qr.address, port: qr.port, path: "/agentpulse/pair/v1",
            subprotocol: "agentpulse.pair.v1", trust: .leaf(name: qr.serverName, fingerprint: qr.leafSha256),
            timeout: max(1, Double(qr.expiresAtUnixSeconds) - Date().timeIntervalSince1970),
            maxBytes: 16_384
        )
        defer { socket.close() }
        try await socket.send(version: "pairing_version", value: 1, message: [
            "type": "pair_request", "pairing_id": qr.pairingId, "bootstrap_token": qr.bootstrapToken,
            "client_id": clientId, "display_name": displayName
        ])
        try decodePairingPending(
            try await socket.receive(version: "pairing_version", value: 1, as: Reply.self),
            clientId: clientId
        )
        let reply = try await socket.receive(version: "pairing_version", value: 1, as: Reply.self)
        if reply.type == "pairing_error" { throw PulseError.host(reply.message ?? "Pairing was rejected.") }
        guard reply.type == "pairing_succeeded", reply.hostId == qr.hostId, reply.serverName == qr.serverName,
              let name = reply.hostName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let address = reply.nativeAddress, validAddress(address),
              let port = reply.nativePort, port > 0, let token = reply.accessToken, !token.isEmpty,
              let encoded = reply.caCertificateDer, let certificate = Data(base64Encoded: encoded),
              SecCertificateCreateWithData(nil, certificate as CFData) != nil,
              reply.nativeTransportVersion == 3, reply.domainProtocolVersions?.contains(2) == true
        else { throw PulseError.invalidReply }
        return Self(hostId: qr.hostId, hostName: name, serverName: qr.serverName,
                    address: address, port: port, certificate: certificate, token: token, clientId: clientId)
    }

    private static func decodePairingPending(_ reply: Reply, clientId: String) throws {
        if reply.type == "pairing_error" { throw PulseError.host(reply.message ?? "Pairing was rejected.") }
        guard reply.type == "pairing_pending", reply.clientId == clientId else { throw PulseError.invalidReply }
    }
}

private struct WireEnvelope<Message: Decodable>: Decodable {
    let pairingVersion: Int?
    let nativeTransportVersion: Int?
    let message: Message
}

final class PulseSocket: Sendable {
    enum Trust: Sendable {
        case leaf(name: String, fingerprint: String)
        case authority(name: String, certificate: Data)
    }

    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(address: String, port: UInt16, path: String, subprotocol: String, trust: Trust,
         headers: [String: String] = [:], timeout: TimeInterval, maxBytes: Int) throws {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = address.contains(":") ? "[\(address)]" : address
        components.port = Int(port)
        components.path = path
        guard let url = components.url else { throw PulseError.invalidQR }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = path.contains("/pair/") ? timeout : 7 * 24 * 3600
        var request = URLRequest(url: url)
        request.setValue(subprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let delegate = PulseSocketDelegate(trust: trust, expectedProtocol: subprotocol)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = maxBytes
        task.resume()
    }

    @MainActor
    func send(version: String, value: Int, message: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: [version: value, "message": message])
        try await withTaskCancellationHandler {
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        } onCancel: {
            close()
        }
    }

    func receive<Message: Decodable>(version: String, value: Int, as _: Message.Type) async throws -> Message {
        let frame = try await withTaskCancellationHandler {
            try await task.receive()
        } onCancel: {
            close()
        }
        guard case .string(let text) = frame else { throw PulseError.invalidReply }
        let envelope = try wireDecoder.decode(WireEnvelope<Message>.self, from: Data(text.utf8))
        let received = version == "pairing_version" ? envelope.pairingVersion : envelope.nativeTransportVersion
        guard received == value else { throw PulseError.invalidReply }
        return envelope.message
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

}

private final class PulseSocketDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    private let trust: PulseSocket.Trust
    private let expectedProtocol: String

    init(trust: PulseSocket.Trust, expectedProtocol: String) {
        self.trust = trust
        self.expectedProtocol = expectedProtocol
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol negotiatedProtocol: String?) {
        if negotiatedProtocol != expectedProtocol {
            webSocketTask.cancel(with: .protocolError, reason: nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust, accepts(serverTrust)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    private func accepts(_ serverTrust: SecTrust) -> Bool {
        switch trust {
        case .leaf(let name, let fingerprint):
            guard let leaf = (SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate])?.first else { return false }
            let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            guard digest.map({ String(format: "%02x", $0) }).joined() == fingerprint else { return false }
            return evaluate(serverTrust, name: name, anchor: leaf)
        case .authority(let name, let der):
            guard let root = SecCertificateCreateWithData(nil, der as CFData) else { return false }
            return evaluate(serverTrust, name: name, anchor: root)
        }
    }

    private func evaluate(_ trust: SecTrust, name: String, anchor: SecCertificate) -> Bool {
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, name as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
        else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
