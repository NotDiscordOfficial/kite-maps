import Foundation
import SwiftUI
import UIKit
import VelaCore

@MainActor
final class DataDiagnostics: ObservableObject {
    @Published var running = false
    @Published var status = "Ready"
    @Published var report: URL?
    @Published var preview: UIImage?

    func run(model: AppModel, includeMap: Bool) {
        guard !running else { return }
        running = true; report = nil; preview = nil; status = "Testing services…"
        let mapImage: Data? = {
            guard includeMap, let map = model.map, map.bounds.width > 0, map.bounds.height > 0 else { return nil }
            let image = UIGraphicsImageRenderer(bounds: map.bounds).image { _ in
                map.drawHierarchy(in: map.bounds, afterScreenUpdates: true)
            }
            return image.pngData()
        }()
        Task {
            var entries: [DiagnosticZip.Entry] = []
            var lines = ["Kite data diagnostics", "Created (UTC): \(ISO8601DateFormatter().string(from: Date()))",
                         "Kite: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"))",
                         "iOS: \(UIDevice.current.systemVersion)", "Test area: fixed Perth tile 10/841/607, not device GPS.",
                         "HR heat layer enabled: \(model.settings.highwayHeatmap), Waze enabled: \(model.settings.wazeOn), plate cameras enabled: \(model.settings.plateCameras)",
                         "Location authorized: \(model.location.authorized), reduced accuracy: \(model.location.reducedAccuracy)",
                         "Map screenshot included: \(mapImage != nil). Screenshot may show private map content.",
                         "No GPS coordinates, saved places or account information are collected by this diagnostic.", ""]
            if let mapImage { entries.append(.init(name: "map-screenshot.png", data: mapImage)) }
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.timeoutIntervalForRequest = 15
            sessionConfig.timeoutIntervalForResource = 25
            let session = URLSession(configuration: sessionConfig)
            defer { session.invalidateAndCancel() }
            let checks: [(String, String)] = [
                ("heatmap", "https://tiles.cmbe.cc/heat_map/get/10/841/607.webp"),
                ("camera", "https://tiles.cmbe.cc/cameras_v2/get/8/210/151.excam")
            ]
            for (name, address) in checks {
                status = "Testing \(name)…"
                let started = Date()
                do {
                    let (data, response) = try await session.data(from: URL(string: address)!)
                    let http = response as? HTTPURLResponse
                    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                    lines.append("\(name): HTTP \(http?.statusCode ?? 0), \(data.count) bytes, \(elapsed) ms, type \(http?.mimeType ?? "unknown")")
                    if name == "heatmap", http?.statusCode == 200, data.count <= 1_000_000 {
                        entries.append(.init(name: "heatmap-original.webp", data: data))
                        if let original = UIImage(data: data) {
                            lines.append("heatmap decode: \(Int(original.size.width)) x \(Int(original.size.height)) points")
                            if let processed = HighwayHeatmap.colour(data), let png = processed.pngData() {
                                entries.append(.init(name: "heatmap-kite.png", data: png))
                                preview = processed
                                lines.append("Kite colour conversion: succeeded (experimental scale)")
                            } else { lines.append("Kite colour conversion: failed") }
                        } else { lines.append("heatmap decode: failed") }
                    }
                    if name == "camera", http?.statusCode != 200 {
                        lines.append("Camera response is unavailable; it is not an empty-camera result.")
                    }
                } catch {
                    lines.append("\(name): request failed: \((error as NSError).domain) code \((error as NSError).code)")
                }
            }
            status = "Testing Waze…"
            let waze = await Waze.alerts(south: -32.00, west: 115.80, north: -31.90, east: 115.92)
            if let waze {
                let police = waze.filter { $0.kind == .police }.count
                lines.append("Waze fixed Perth test: \(waze.count) reports, \(police) police. No report locations saved.")
            } else { lines.append("Waze fixed Perth test: request failed or could not be decoded.") }
            lines.append("\nHeatmap colours are experimental. A successful download does not prove correct map alignment.")
            entries.insert(.init(name: "diagnostics.txt", data: Data(lines.joined(separator: "\n").utf8)), at: 0)
            do {
                let zip = try DiagnosticZip.archive(entries)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kite-Diagnostics-\(UUID().uuidString).zip")
                try zip.write(to: url, options: .atomic)
                report = url; status = "Report ready. Review it before sharing."
            } catch { status = "Could not create report: \(error.localizedDescription)" }
            running = false
        }
    }
}

struct DataDiagnosticsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var diagnostics = DataDiagnostics()
    @State private var includeMap = false

    var body: some View {
        Form {
            Section {
                Text("Tests Highway Radar historical tiles, its camera endpoint and Waze using a fixed Perth test area. Results and images are packaged into a ZIP.")
                Toggle("Include current map screenshot", isOn: $includeMap)
                if includeMap {
                    Text("The screenshot can reveal your position, searches and other map content. Review it before sharing.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                Button(diagnostics.running ? "Testing…" : "Run tests and prepare ZIP") {
                    diagnostics.run(model: model, includeMap: includeMap)
                }.disabled(diagnostics.running)
                Text(diagnostics.status).font(.footnote).foregroundColor(.secondary)
            } header: { Text("On-device data tests") }
            if let image = diagnostics.preview {
                Section("Kite heat tile preview") {
                    Image(uiImage: image).resizable().interpolation(.none).scaledToFit().frame(maxWidth: 256)
                    Text("Experimental colours, not a map alignment test.").font(.footnote).foregroundColor(.secondary)
                }
            }
            if let report = diagnostics.report {
                Section("Export") {
                    ShareLink(item: report) { Label("Share diagnostic ZIP", systemImage: "square.and.arrow.up") }
                    Text("Share the ZIP back in this chat. The file remains on this device until you choose where to send it.")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
        }
        .kiteList()
        .navigationTitle("Data diagnostics")
    }
}
