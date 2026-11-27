import CoreImage
import ImageIO
import Observation
import Security
import SwiftUI
import UniformTypeIdentifiers
import Vision
#if os(iOS)
import PhotosUI
#endif

private enum CredentialStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "moe.gensoukyo.agentpulse",
         kSecAttrAccount as String: "direct-host"]
    }

    static func load() throws -> HostCredential? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PulseError.keychain(status) }
        return try JSONDecoder().decode(HostCredential.self, from: data)
    }

    static func save(_ credential: HostCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw PulseError.keychain(status) }
        var item = query
        item[kSecValueData as String] = data
        #if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw PulseError.keychain(added) }
    }

    static func forget() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PulseError.keychain(status) }
    }
}

private enum QRImage {
    static func read(url: URL) async throws -> PairingBundle {
        try await Task.detached {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw PulseError.invalidQR }
            return try read(source: source)
        }.value
    }

    #if os(iOS)
    static func read(data: Data) async throws -> PairingBundle {
        try await Task.detached {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw PulseError.invalidQR }
            return try read(source: source)
        }.value
    }

    #endif

    private static func read(source: CGImageSource) throws -> PairingBundle {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 2_048] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw PulseError.invalidQR }
        let normal = try codes(in: VNImageRequestHandler(cgImage: image))
        if !normal.isEmpty { return try decode(normal) }
        // Terminal themes can render the dark QR modules in white.
        let inverted = CIImage(cgImage: image).applyingFilter("CIColorInvert")
        return try decode(codes(in: VNImageRequestHandler(ciImage: inverted)))
    }

    private static func codes(in handler: VNImageRequestHandler) throws -> [VNBarcodeObservation] {
        let scan = VNDetectBarcodesRequest()
        scan.symbologies = [.qr]
        try handler.perform([scan])
        return scan.results ?? []
    }

    private static func decode(_ codes: [VNBarcodeObservation]) throws -> PairingBundle {
        guard codes.count == 1, let value = codes.first?.payloadStringValue else { throw PulseError.invalidQR }
        return try PairingBundle.parse(value)
    }
}

@MainActor
@Observable
private final class Dashboard {
    private let observer = NativeObserver()
    private var job: Task<Void, Never>?
    private var loaded = false

    private(set) var credential: HostCredential?
    private(set) var feeds: [SessionFeed] = []
    private(set) var status = "Disconnected"
    private(set) var busy = false
    private(set) var active = false
    var error: String?

    private var deviceName: String {
        #if os(macOS)
        "AgentPulse for Mac"
        #else
        "AgentPulse for iPhone"
        #endif
    }

    init() {
        observer.onUpdate = { [weak self] feeds in self?.feeds = feeds }
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        do {
            credential = try CredentialStore.load()
            if credential != nil { connect() }
        } catch { self.error = error.localizedDescription }
    }

    func pair(read: @escaping @MainActor () async throws -> PairingBundle) {
        guard !busy else { return }
        stop()
        error = nil
        busy = true
        status = "Reading pairing QR code…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let qr = try await read()
                try Task.checkCancellation()
                status = "Confirm the pairing request in the Host terminal…"
                let client = credential?.clientId ?? uuidV7()
                let newHost = try await HostCredential.pair(using: qr, clientId: client, displayName: deviceName)
                try Task.checkCancellation()
                try CredentialStore.save(newHost)
                observer.reset()
                credential = newHost
                busy = false
                connect()
            } catch {
                guard !Task.isCancelled else { return }
                busy = false
                status = "Disconnected"
                self.error = error.localizedDescription
            }
        }
    }

    func connect() {
        guard let credential, !busy else { return }
        stop()
        error = nil
        status = "Connecting…"
        active = true
        job = Task { [weak self] in
            guard let self else { return }
            do {
                try await observer.run(credential: credential, displayName: deviceName) {
                    self.status = "Connected"
                }
            } catch {
                guard !Task.isCancelled else { return }
                active = false
                status = "Disconnected"
                self.error = error.localizedDescription
            }
        }
    }

    func stop() {
        job?.cancel()
        job = nil
        observer.disconnect()
        busy = false
        active = false
        status = "Disconnected"
    }

    func forget() {
        stop()
        do {
            try CredentialStore.forget()
            credential = nil
            observer.reset()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

@main
struct AgentPulseApp: App {
    var body: some Scene {
        #if os(macOS)
        Window("AgentPulse", id: "agentpulse") { DashboardView() }
        #else
        WindowGroup { DashboardView() }
        #endif
    }
}

private struct DashboardView: View {
    @State private var model = Dashboard()
    @State private var importing = false
    @State private var confirmingForget = false
    @State private var selection: String?
    #if os(iOS)
    @State private var photo: PhotosPickerItem?
    #endif

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Host") {
                    if let host = model.credential { Text(host.hostName).font(.headline) }
                    Text(model.status).font(.subheadline).foregroundStyle(.secondary)
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    Button("Import Pairing QR Image", systemImage: "qrcode") { importing = true }
                        .disabled(model.busy)
                    #if os(iOS)
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Choose QR from Photos", systemImage: "photo")
                    }
                    .disabled(model.busy)
                    #endif
                    if model.busy || model.active {
                        Button(model.busy ? "Cancel Pairing" : "Disconnect") { model.stop() }
                    } else if model.credential != nil {
                        Button("Connect") { model.connect() }
                    }
                    if model.credential != nil {
                        Button("Forget Host", role: .destructive) { confirmingForget = true }
                            .disabled(model.busy)
                    }
                }
                Section("Sessions") {
                    if model.feeds.isEmpty {
                        Text("No sessions available").foregroundStyle(.secondary)
                    }
                    ForEach(model.feeds) { feed in
                        NavigationLink(value: feed.id) {
                            VStack(alignment: .leading) {
                                Text(feed.summary.name).lineLimit(2)
                                Text(feed.summary.state.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("AgentPulse")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 250, ideal: 315)
            #endif
        } detail: {
            if let feed = model.feeds.first(where: { $0.id == selection }) {
                SessionDetail(feed: feed)
            } else {
                ContentUnavailableView(
                    model.credential == nil ? "Pair a Host" : "Select a Session",
                    systemImage: model.credential == nil ? "qrcode" : "list.bullet.rectangle",
                    description: model.credential == nil ? Text("Import an image of the direct pairing QR code from the Host terminal.") : nil
                )
            }
        }
        .task { model.load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): model.pair { try await QRImage.read(url: url) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        #if os(iOS)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            model.pair {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw PulseError.invalidQR }
                return try await QRImage.read(data: data)
            }
        }
        #endif
        .confirmationDialog("Remove saved credentials for this Host?", isPresented: $confirmingForget) {
            Button("Forget Host", role: .destructive) { selection = nil; model.forget() }
        }
    }
}

private struct SessionDetail: View {
    let feed: SessionFeed

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("State", value: feed.summary.state.replacingOccurrences(of: "_", with: " "))
                LabeledContent("Connection", value: feed.summary.connectionState)
                if let path = feed.summary.workspace?.path { Text(path).textSelection(.enabled) }
            }
            if !feed.pending.isEmpty {
                Section("Waiting for input on the Host") {
                    ForEach(feed.pending.values.sorted { $0.id < $1.id }) { request in
                        Text(request.prompt).textSelection(.enabled)
                    }
                }
            }
            Section("Recent Events") {
                if feed.events.isEmpty { Text("No events yet").foregroundStyle(.secondary) }
                ForEach(feed.events.reversed()) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.payload.type.replacingOccurrences(of: "_", with: " ").capitalized).font(.headline)
                        if let detail = event.payload.detail { Text(detail).textSelection(.enabled) }
                        Text(event.occurredAt).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(feed.summary.name)
    }
}
