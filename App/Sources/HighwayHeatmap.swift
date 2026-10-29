import UIKit
import MapLibre

/// Experimental visualization of Highway Radar's grayscale historical tiles.
/// Tiles are fetched only while enabled. Colours are an approximation, not its official scale.
@MainActor
final class HighwayHeatmap {
    private struct Tile: Hashable {
        let z: Int, x: Int, y: Int
        var id: String { "vela-highway-heat-\(z)-\(x)-\(y)" }
        var url: URL { URL(string: "https://tiles.cmbe.cc/heat_map/get/\(z)/\(x)/\(y).webp")! }
        func longitude(_ x: Int) -> Double { Double(x) / pow(2, Double(z)) * 360 - 180 }
        func latitude(_ y: Int) -> Double { atan(sinh(.pi * (1 - 2 * Double(y) / pow(2, Double(z))))) * 180 / .pi }
        var quad: MLNCoordinateQuad {
            MLNCoordinateQuad(topLeft: .init(latitude: latitude(y), longitude: longitude(x)),
                              bottomLeft: .init(latitude: latitude(y + 1), longitude: longitude(x)),
                              bottomRight: .init(latitude: latitude(y + 1), longitude: longitude(x + 1)),
                              topRight: .init(latitude: latitude(y), longitude: longitude(x + 1)))
        }
    }
    private var generation = 0
    private var wanted: Set<Tile> = []
    private var tasks: [Tile: Task<Void, Never>] = [:]
    private var installed: Set<Tile> = []
    private weak var currentStyle: MLNStyle?

    func update(_ map: MLNMapView, enabled: Bool) {
        guard let style = map.style else { return }
        if currentStyle !== style {
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
            currentStyle = style; installed.removeAll(); wanted.removeAll(); generation += 1
        }
        let bounds = map.visibleCoordinateBounds
        var z = min(14, max(5, Int(map.zoomLevel)))
        func tileXY(_ lat: Double, _ lon: Double, _ z: Int) -> (Int, Int) {
            let n = Double(1 << z), phi = max(-85.05, min(85.05, lat)) * .pi / 180
            let x = Int(floor((max(-180, min(179.999999, lon)) + 180) / 360 * n))
            let y = Int(floor((1 - asinh(tan(phi)) / .pi) / 2 * n))
            return (max(0, min(Int(n)-1, x)), max(0, min(Int(n)-1, y)))
        }
        var tiles: Set<Tile> = []
        if enabled && bounds.sw.longitude <= bounds.ne.longitude {
            while z >= 5 {
                let nw = tileXY(bounds.ne.latitude, bounds.sw.longitude, z)
                let se = tileXY(bounds.sw.latitude, bounds.ne.longitude, z)
                if se.0 >= nw.0 && se.1 >= nw.1 && (se.0 - nw.0 + 1) * (se.1 - nw.1 + 1) <= 16 {
                    for x in nw.0...se.0 { for y in nw.1...se.1 { tiles.insert(Tile(z: z, x: x, y: y)) } }
                    break
                }
                z -= 1
            }
        }
        guard tiles != wanted else { return }
        generation += 1
        let revision = generation
        wanted = tiles
        for (tile, task) in tasks where !tiles.contains(tile) { task.cancel(); tasks[tile] = nil }
        for tile in installed.subtracting(tiles) {
            if let layer = style.layer(withIdentifier: tile.id) { style.removeLayer(layer) }
            if let source = style.source(withIdentifier: tile.id) { style.removeSource(source) }
            installed.remove(tile)
        }
        for tile in tiles.subtracting(installed) where tasks[tile] == nil {
            tasks[tile] = Task { [weak self, weak map] in
                defer { self?.tasks[tile] = nil }
                do {
                    let (data, response) = try await URLSession.shared.data(from: tile.url)
                    guard !Task.isCancelled, let http = response as? HTTPURLResponse, http.statusCode == 200,
                          data.count <= 1_000_000, let image = Self.colour(data), let self, let map,
                          self.wanted.contains(tile), self.generation >= revision, let style = map.style,
                          self.currentStyle === style else { return }
                    let source = MLNImageSource(identifier: tile.id, coordinateQuad: tile.quad, image: image)
                    style.addSource(source)
                    let layer = MLNRasterStyleLayer(identifier: tile.id, source: source)
                    layer.rasterFadeDuration = NSExpression(forConstantValue: 0)
                    if let above = style.layers.first(where: { $0 is MLNSymbolStyleLayer }) { style.insertLayer(layer, below: above) }
                    else { style.addLayer(layer) }
                    self.installed.insert(tile)
                } catch { /* Unavailable tiles remain absent rather than implying no activity. */ }
            }
        }
    }

    static func colour(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data)?.cgImage, image.width == 256, image.height == 256 else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let intensity = Double(pixels[i]) / 255
            let alpha = max(0, min(0.7, (intensity - 0.08) * 1.2))
            let red = min(1, intensity * 2), blue = max(0, 1 - intensity * 1.3)
            pixels[i] = UInt8(red * alpha * 255)
            pixels[i + 1] = UInt8(max(0, 0.9 - abs(intensity - 0.5) * 1.8) * alpha * 200)
            pixels[i + 2] = UInt8(blue * alpha * 255)
            pixels[i + 3] = UInt8(alpha * 255)
        }
        guard let result = ctx.makeImage() else { return nil }
        return UIImage(cgImage: result)
    }
}
