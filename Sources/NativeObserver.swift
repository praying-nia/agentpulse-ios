import Foundation

struct SessionSummary: Decodable, Identifiable {
    let id: String
    let title: String?
    let state: String
    let connectionState: String
    let updatedAt: String
    let workspace: Workspace?

    struct Workspace: Decodable {
        let path: String?
        let displayName: String?
    }

    var name: String { title ?? workspace?.displayName ?? workspace?.path ?? id }
}

struct Interaction: Decodable, Identifiable {
    let id: String
    let prompt: String
    let sessionId: String
}

struct SessionEvent: Decodable, Identifiable {
    let id: String
    let sessionId: String
    let sequence: String
    let occurredAt: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String
        let state: String?
        let connectionState: String?
        let message: Message?
        let plan: Plan?
        let activity: Activity?
        let progress: Progress?
        let outcome: Outcome?
        let request: Interaction?
        let response: Resolution?
        let interaction: Resolution?

        struct Message: Decodable { let role: String; let content: String }
        struct Plan: Decodable {
            let explanation: String?
            let items: [Item]
            struct Item: Decodable { let content: String; let status: String }
        }
        struct Activity: Decodable { let name: String?; let summary: String?; let outcome: String? }
        struct Progress: Decodable { let message: String?; let value: Value
            struct Value: Decodable { let completed: String?; let total: String? }
        }
        struct Outcome: Decodable { let type: String; let summary: String?; let error: String?; let reason: String? }
        struct Resolution: Decodable { let requestId: String }

        var detail: String? {
            if let message { return "\(message.role): \(message.content)" }
            if let plan {
                let items = plan.items.map { "\($0.status) · \($0.content)" }
                return ([plan.explanation].compactMap { $0 } + items).joined(separator: "\n")
            }
            if let activity { return activity.summary ?? activity.name ?? activity.outcome }
            if let progress {
                if let message = progress.message { return message }
                if let completed = progress.value.completed, let total = progress.value.total { return "\(completed)/\(total)" }
            }
            if let outcome { return outcome.summary ?? outcome.error ?? outcome.reason ?? outcome.type }
            return request?.prompt ?? state ?? connectionState
        }
    }
}

struct SessionFeed: Identifiable {
    var summary: SessionSummary
    var cursor: UInt64 = 0
    var events: [SessionEvent] = []
    var pending: [String: Interaction] = [:]

    var id: String { summary.id }

    mutating func append(_ event: SessionEvent) throws {
        guard cursor < UInt64.max, event.sessionId == id, event.sequence == String(cursor + 1) else {
            throw PulseError.host("The event sequence changed unexpectedly. Reconnect to synchronize again.")
        }
        cursor += 1
        events.append(event)
        if events.count > 250 { events.removeFirst(events.count - 250) }
        if let request = event.payload.request { pending[request.id] = request }
        if let requestId = event.payload.response?.requestId ?? event.payload.interaction?.requestId {
            pending.removeValue(forKey: requestId)
        }
        if event.payload.type == "session_ended" { pending.removeAll() }
    }
}

private struct NativeFrame: Decodable {
    let type: String
    let requestId: String?
    let protocolVersion: Int?
    let hostRunId: String?
    let resumeAccepted: Bool?
    let providerCount: Int?
    let sessionCount: Int?
    let sessionId: String?
    let status: String?
    let baselineSequence: String?
    let eventCount: Int?
    let pendingInteractionCount: Int?
    let reset: Bool?
    let message: String?
    let recoverable: Bool?
    let context: Context?
    let domain: Domain?

    struct Context: Decodable {
        let type: String
        let requestId: String?
    }

    struct Domain: Decodable {
        let protocolVersion: Int
        let message: Message

        struct Message: Decodable {
            let type: String
            let summary: SessionSummary?
            let event: SessionEvent?
            let interaction: Interaction?

            private enum CodingKeys: String, CodingKey { case type, payload }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                type = try container.decode(String.self, forKey: .type)
                summary = type == "agent_session" ? try container.decode(SessionSummary.self, forKey: .payload) : nil
                event = type == "agent_event" ? try container.decode(SessionEvent.self, forKey: .payload) : nil
                interaction = type == "interaction_request" ? try container.decode(Interaction.self, forKey: .payload) : nil
            }
        }
    }
}

@MainActor
final class NativeObserver {
    private var hostRunId: String?
    private var feeds: [String: SessionFeed] = [:]
    private var subscribed: Set<String> = []
    private var visible: Set<String> = []
    private var socket: PulseSocket?
    private var awaitingDiscovery = false
    private var refreshId: String?

    var onUpdate: (([SessionFeed]) -> Void)?

    func reset() {
        disconnect()
        hostRunId = nil
        feeds.removeAll()
        visible.removeAll()
        publish()
    }

    func disconnect() {
        socket?.close()
        socket = nil
    }

    func run(credential: HostCredential, displayName: String, onConnected: () -> Void) async throws {
        let connection = try PulseSocket(
            address: credential.address, port: credential.port, path: "/agentpulse/native/v3",
            subprotocol: "agentpulse.native.v3",
            trust: .authority(name: credential.serverName, certificate: credential.certificate),
            headers: ["Authorization": "Bearer \(credential.token)", "X-AgentPulse-Client-Id": credential.clientId],
            timeout: 60, maxBytes: 1_048_576
        )
        socket = connection
        defer {
            connection.close()
            if socket === connection { socket = nil }
        }
        subscribed.removeAll()
        awaitingDiscovery = false
        refreshId = nil
        var hello: [String: Any] = [
            "type": "client_hello", "client_id": credential.clientId, "display_name": displayName,
            "supported_protocol_versions": [2]
        ]
        if let hostRunId {
            hello["host_run_id"] = hostRunId
            hello["session_cursors"] = feeds.values.filter { $0.cursor > 0 }.map {
                ["session_id": $0.id, "last_sequence": String($0.cursor)]
            }
        }
        try await send(hello, over: connection)
        let reply = try await next(over: connection)
        guard reply.type == "server_hello", reply.protocolVersion == 2,
              let runId = reply.hostRunId, let resumed = reply.resumeAccepted else { throw PulseError.invalidReply }
        if !resumed || runId != hostRunId {
            feeds.removeAll()
            visible.removeAll()
            publish()
        }
        hostRunId = runId
        onConnected()

        // The Host has no unsolicited discovery notification. Keep existing subscriptions
        // live while polling for sessions started after connecting.
        let refresh = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                    guard socket === connection else { return }
                    if awaitingDiscovery, refreshId == nil { try await requestDiscovery(over: connection) }
                } catch {
                    if !Task.isCancelled { connection.close() }
                    return
                }
            }
        }
        defer { refresh.cancel() }

        try await requestDiscovery(over: connection)
        while !Task.isCancelled {
            awaitingDiscovery = true
            let start = try await next(over: connection)
            awaitingDiscovery = false
            guard let id = refreshId else { throw PulseError.invalidReply }
            refreshId = nil
            try await discover(start: start, id: id, over: connection)
        }
    }

    private func requestDiscovery(over connection: PulseSocket) async throws {
        let id = uuidV7()
        refreshId = id
        try await send(["type": "discover_sessions", "request_id": id], over: connection)
    }

    private func discover(start: NativeFrame, id: String, over connection: PulseSocket) async throws {
        guard start.type == "sync_started", start.requestId == id,
              let providers = start.providerCount, providers >= 0,
              let count = start.sessionCount, count >= 0 else { throw PulseError.invalidReply }
        for _ in 0..<providers {
            let frame = try await next(over: connection)
            guard frame.context?.type == "discovery_provider", frame.context?.requestId == id,
                  frame.domain?.message.type == "provider_descriptor" else { throw PulseError.invalidReply }
        }
        var summaries: [SessionSummary] = []
        for _ in 0..<count {
            let frame = try await next(over: connection)
            guard frame.context?.type == "discovery_session", frame.context?.requestId == id,
                  let summary = frame.domain?.message.summary else { throw PulseError.invalidReply }
            summaries.append(summary)
        }
        try await complete(id, over: connection)
        visible = Set(summaries.map(\.id))
        for summary in summaries {
            if feeds[summary.id] != nil { feeds[summary.id]?.summary = summary }
            else { feeds[summary.id] = SessionFeed(summary: summary) }
        }
        publish()
        for summary in summaries where !subscribed.contains(summary.id) {
            do {
                try await subscribe(summary, over: connection)
            } catch let rejection as SubscriptionRejected {
                if !rejection.recoverable { throw rejection }
            }
        }
    }

    private func subscribe(_ summary: SessionSummary, over connection: PulseSocket) async throws {
        while true {
            let requestId = uuidV7()
            try await send(["type": "subscribe_session", "request_id": requestId, "session_id": summary.id], over: connection)
            let start = try await next(over: connection, subscription: requestId)
            guard start.type == "subscription_result", start.requestId == requestId, start.sessionId == summary.id,
                  let status = start.status, let baseline = start.baselineSequence, let reset = start.reset
            else { throw PulseError.invalidReply }
            if status == "already_subscribed" {
                subscribed.insert(summary.id)
                return
            }
            guard status == "catching_up" || status == "subscribed", let count = start.eventCount, (0...128).contains(count),
                  let pendingCount = start.pendingInteractionCount, pendingCount >= 0
            else { throw PulseError.invalidReply }
            var page = (reset ? nil : feeds[summary.id]) ?? SessionFeed(summary: summary)
            for _ in 0..<count {
                let frame = try await next(over: connection)
                guard frame.context?.type == "live_event", let event = frame.domain?.message.event else {
                    throw PulseError.invalidReply
                }
                try page.append(event)
            }
            guard String(page.cursor) == baseline else { throw PulseError.invalidReply }
            if status == "subscribed" {
                let frame = try await next(over: connection)
                guard frame.context?.type == "subscription_session", frame.context?.requestId == requestId,
                      let current = frame.domain?.message.summary, current.id == summary.id else {
                    throw PulseError.invalidReply
                }
                page.summary = current
                page.pending.removeAll()
                for _ in 0..<pendingCount {
                    let frame = try await next(over: connection)
                    guard frame.context?.type == "subscription_interaction", frame.context?.requestId == requestId,
                          let request = frame.domain?.message.interaction, request.sessionId == summary.id else {
                        throw PulseError.invalidReply
                    }
                    page.pending[request.id] = request
                }
            } else if count == 0 || pendingCount != 0 {
                throw PulseError.invalidReply
            }
            try await complete(requestId, over: connection)
            feeds[summary.id] = page
            publish()
            if status == "subscribed" {
                subscribed.insert(summary.id)
                return
            }
        }
    }

    private struct SubscriptionRejected: LocalizedError {
        let reason: String
        let recoverable: Bool
        var errorDescription: String? { reason }
    }

    private func next(over connection: PulseSocket,
                      subscription: String? = nil) async throws -> NativeFrame {
        while true {
            let frame = try await connection.receive(version: "native_transport_version", value: 3, as: NativeFrame.self)
            guard socket === connection, !Task.isCancelled else { throw CancellationError() }
            if frame.type == "error" {
                let message = frame.message ?? "The Host rejected a request."
                if let subscription, frame.requestId == subscription {
                    throw SubscriptionRejected(reason: message, recoverable: frame.recoverable == true)
                }
                throw PulseError.host(message)
            }
            if let domain = frame.domain, domain.protocolVersion != 2 { throw PulseError.invalidReply }
            if frame.context?.type == "live_session", let summary = frame.domain?.message.summary,
               subscribed.contains(summary.id) {
                feeds[summary.id]?.summary = summary
                publish()
                continue
            }
            if frame.context?.type == "live_event", let event = frame.domain?.message.event,
               subscribed.contains(event.sessionId) {
                try feeds[event.sessionId]?.append(event)
                publish()
                continue
            }
            return frame
        }
    }

    private func complete(_ id: String, over connection: PulseSocket) async throws {
        let frame = try await next(over: connection)
        guard frame.type == "sync_completed", frame.requestId == id else { throw PulseError.invalidReply }
    }

    private func send(_ message: [String: Any], over connection: PulseSocket) async throws {
        try await connection.send(version: "native_transport_version", value: 3, message: message)
    }

    private func publish() {
        onUpdate?(visible.compactMap { feeds[$0] }.sorted {
            if $0.summary.updatedAt == $1.summary.updatedAt { return $0.id < $1.id }
            return $0.summary.updatedAt > $1.summary.updatedAt
        })
    }
}
