import SwiftUI
import Network
import UIKit
import VelaCore

/// Experimental, read-only discovery and /info diagnostics. No pairing or streaming yet.
@MainActor
final class ReceiverDiagnostics: ObservableObject {
    struct Device: Identifiable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }
    @Published var devices: [Device] = []
    @Published var status = "Start discovery to find AirPlay-advertising devices."
    @Published var result = ""
    @Published var report: URL?
    private var events: [String] = []
    private var mode = "info"
    private var startedAt = Date()

    private func record(_ message: String) {
        events.append("\(ISO8601DateFormatter().string(from: Date()))  \(message)")
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var generation = UUID()
    private var bytes = Data()

    func start() {
        stop()
        devices = []
        status = "Searching on the current network…"
        record("Discovery started for _airplay._tcp")
        let browser = NWBrowser(for: .bonjour(type: "_airplay._tcp", domain: nil), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready: self.status = "Searching on the current network."
                case .waiting(let error): self.status = "Discovery waiting: \(error.localizedDescription)"; self.record("Discovery waiting")
                case .failed(let error): self.status = "Discovery failed: \(error.localizedDescription)"; self.record("Discovery failed")
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { item -> Device? in
                guard case let .service(name, _, _, _) = item.endpoint else { return nil }
                return Device(id: String(describing: item.endpoint), name: name, endpoint: item.endpoint)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self?.devices = found
                self?.record("Discovery found \(found.count) service(s); device names omitted")
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        generation = UUID()
        browser?.cancel(); browser = nil
        connection?.cancel(); connection = nil
    }

    func probe(_ endpoint: NWEndpoint, options: Bool = false) {
        mode = options ? "OPTIONS" : "GET /info"
        startedAt = Date()
        record("\(mode) started; receiver address omitted")
        connection?.cancel()
        bytes = Data()
        let token = UUID()
        generation = token
        result = "Connecting for read-only \(mode)…"
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            DispatchQueue.main.async {
                guard let self, let conn, self.generation == token else { return }
                switch state {
                case .ready:
                    if let path = conn.currentPath {
                        let route = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.cellular) ? "cellular" : "other"
                        self.record("Connection ready over \(route)")
                    }
                    conn.send(content: options ? ReceiverProbe.optionsRequest : ReceiverProbe.request, completion: .contentProcessed { error in
                        DispatchQueue.main.async {
                            guard self.generation == token else { return }
                            if let error { self.finish("Send failed: \(error.localizedDescription)", token: token) }
                            else { self.receive(conn, token: token) }
                        }
                    })
                case .failed(let error): self.finish("Connection failed: \(error.localizedDescription)", token: token)
                case .waiting(let error): self.result = "Waiting: \(error.localizedDescription)"
                default: break
                }
            }
        }
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.finish("No complete response within 8 seconds.", token: token)
        }
    }

    private func receive(_ conn: NWConnection, token: UUID) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self, weak conn] data, _, complete, error in
            DispatchQueue.main.async {
                guard let self, let conn, self.generation == token else { return }
                if let data { self.bytes.append(data) }
                do {
                    if let response = try ReceiverProbe.parse(self.bytes) {
                        let detail = response.status == 455 ? " The receiver rejected this request in its current state; this probe has not established a session." : " A reply does not establish CarPlay compatibility or a session."
                        if let methods = response.headers["public"] {
                            if methods.range(of: "^[A-Za-z0-9 ,_-]{1,200}$", options: .regularExpression) != nil {
                                self.record("Public methods: \(methods)")
                            } else { self.record("Public methods: invalid or omitted") }
                        }
                        self.record("Response CSeq: \(response.headers["cseq"].flatMap(Int.init).map(String.init) ?? "missing or invalid"), body bytes: \(response.body.count)")
                        self.finish("RTSP \(response.status), \(response.body.count) body bytes." + detail, token: token)
                    } else if complete || error != nil {
                        self.finish("Connection closed before a complete RTSP reply.", token: token)
                    } else { self.receive(conn, token: token) }
                } catch { self.finish("Invalid or oversized RTSP response.", token: token) }
            }
        }
    }

    private func finish(_ message: String, token: UUID) {
        guard generation == token else { return }
        generation = UUID()
        result = message
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        let summary: String
        if message.hasPrefix("RTSP ") { summary = message }
        else if message.hasPrefix("No complete") { summary = "Timed out" }
        else if message.hasPrefix("Invalid") { summary = "Invalid or oversized response" }
        else { summary = "Connection or send failed; details omitted" }
        record("\(mode): \(summary) (\(elapsed) ms)")
        connection?.cancel(); connection = nil
    }
    func encodeTest() -> String {
        do {
            let frame = try H264TestPattern.encode()
            let message = "Encoded one H.264 frame (\(frame.avcc.count) bytes). No video was sent."
            record(message)
            return message
        } catch {
            record("Local H.264 encoder failed")
            return "Encoder test failed: \(error)"
        }
    }

    func makeReport() {
        let header = ["Kite receiver diagnostics", "Generated UTC: \(ISO8601DateFormatter().string(from: Date()))",
                      "App version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")",
                      "Running bundle: \(Bundle.main.bundleIdentifier ?? "unknown")", "iOS: \(UIDevice.current.systemVersion)",
                      "Receiver names, IP addresses and raw response bodies are omitted.",
                      "Read-only probes do not establish a CarPlay session. No video or audio sent.", ""]
        do {
            let zip = try DiagnosticZip.archive([.init(name: "receiver-diagnostics.txt", data: Data((header + events).joined(separator: "\n").utf8))])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-Receiver-\(UUID().uuidString).zip")
            try zip.write(to: url, options: .atomic)
            report = url
        } catch { result = "Unable to prepare report: \(error.localizedDescription)" }
    }
}

struct ReceiverDiagnosticsView: View {
    @StateObject private var diagnostics = ReceiverDiagnostics()
    @State private var host = ""
    @State private var port = ""
    @State private var encoderResult = ""
    @State private var useOptions = false

    var body: some View {
        Form {
            Section {
                Text("Experimental discovery and read-only diagnostics. Streaming, pairing and head-unit controls are not implemented yet.")
                Toggle("Use RTSP OPTIONS probe", isOn: $useOptions)
                Button("Find receivers") { diagnostics.start() }
                Text(diagnostics.status).font(.footnote).foregroundColor(.secondary)
                ForEach(diagnostics.devices) { device in
                    Button(device.name) { diagnostics.probe(device.endpoint, options: useOptions) }
                }
            } header: { Text("Nearby AirPlay services") }
            footer: { Text("A listed device may be a TV or speaker, not a CarPlay receiver. Connect to the receiver's network first.") }
            Section("Manual address") {
                TextField("IP address or hostname", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", text: $port).keyboardType(.numberPad)
                Button("Check receiver") {
                    guard let number = UInt16(port), number > 0, let p = NWEndpoint.Port(rawValue: number) else { return }
                    diagnostics.probe(.hostPort(host: NWEndpoint.Host(host.trimmingCharacters(in: .whitespacesAndNewlines)), port: p), options: useOptions)
                }.disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || UInt16(port) == nil || UInt16(port) == 0)
            }
            if !diagnostics.result.isEmpty { Section("Result") { Text(diagnostics.result) } }
            Section("Local encoder test") {
                Button("Encode a test pattern") {
                    encoderResult = diagnostics.encodeTest()
                }
                if !encoderResult.isEmpty { Text(encoderResult).font(.footnote) }
            }
            Section("Export receiver log") {
                Button("Prepare receiver ZIP") { diagnostics.makeReport() }
                if let report = diagnostics.report { ShareLink(item: report) { Label("Share receiver ZIP", systemImage: "square.and.arrow.up") } }
                Text("Includes probe outcomes and timing. Receiver names, IP addresses and raw replies are omitted.").font(.footnote).foregroundColor(.secondary)
            }
        }
        .kiteList()
        .navigationTitle("Receiver diagnostics")
        .onDisappear { diagnostics.stop() }
    }
}
