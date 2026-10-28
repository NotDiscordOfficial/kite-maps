import MapLibre
import UIKit

/**
 * Paints OpenFreeMap Liberty in Kite's colors: a calm Waze-like night palette (slate land,
 * soft blue-grey roads with no dark edges, green parks) and the classic day look (white
 * streets, yellow motorways). While driving, [drive] strips the map down to roads and names.
 * Layer ids are Liberty's; anything not named here keeps Liberty's own style.
 */
enum MapStyler {
    struct Palette {
        var land, water, park, pitch, landuse: UIColor
        var landuseOpacity: Double
        var building, buildingOutline: UIColor
        var minor, major, motorway, service, path: UIColor
        var casing, motorwayCasing: UIColor
        var rail: UIColor
        var airport, runway: UIColor
        var label: UIColor?, halo: UIColor?
        var roadLabel: UIColor, roadHalo: UIColor
        var border: UIColor
    }

    static let dark = Palette(
        land: UIColor(hex: 0x262E3B), water: UIColor(hex: 0x253F5C), park: UIColor(hex: 0x24563F),
        pitch: UIColor(hex: 0x24563F), landuse: UIColor(hex: 0x2B3442), landuseOpacity: 0.5,
        building: UIColor(hex: 0x2D3644), buildingOutline: UIColor(hex: 0x313B4A),
        minor: UIColor(hex: 0x3B4C5B), major: UIColor(hex: 0x46606F), motorway: UIColor(hex: 0x587689),
        service: UIColor(hex: 0x333F4D), path: UIColor(hex: 0x2F3947),
        casing: UIColor(hex: 0x262E3B), motorwayCasing: UIColor(hex: 0x262E3B),
        rail: UIColor(hex: 0x3A4655),
        airport: UIColor(hex: 0x2B3442), runway: UIColor(hex: 0x3B4C5B),
        label: UIColor(hex: 0xC9D1DC), halo: UIColor(hex: 0x262E3B),
        roadLabel: UIColor(hex: 0xE2E8F0), roadHalo: UIColor(hex: 0x262E3B),
        border: UIColor(hex: 0x8C95A3))

    static let light = Palette(
        land: UIColor(hex: 0xF2F1EE), water: UIColor(hex: 0x90DAEE), park: UIColor(hex: 0xCFECCD),
        pitch: UIColor(hex: 0xD3F8E2), landuse: UIColor(hex: 0xF2F1EE), landuseOpacity: 1,
        building: UIColor(hex: 0xDDE1E7), buildingOutline: UIColor(hex: 0xC4C9D1),
        minor: .white, major: .white, motorway: UIColor(hex: 0xF9D27A),
        service: .white, path: UIColor(hex: 0xDCDFE4),
        casing: UIColor(hex: 0xDADDE2), motorwayCasing: UIColor(hex: 0xF0B85A),
        rail: UIColor(hex: 0xC4C9D1),
        airport: UIColor(hex: 0xE6E8EC), runway: UIColor(hex: 0xD0D4DA),
        label: nil, halo: nil,
        roadLabel: UIColor(hex: 0x5F6368), roadHalo: .white,
        border: UIColor(hex: 0x9AA0A6))

    private static func c(_ u: UIColor) -> NSExpression { NSExpression(forConstantValue: u) }

    static func apply(_ style: MLNStyle, dark: Bool) {
        let p = dark ? Self.dark : Self.light
        for layer in style.layers {
            let id = layer.identifier
            // Vela's own layers keep their colors (the transit lines' ids contain "rail").
            if id.hasPrefix("vela") { continue }
            if id == "natural_earth" || id == "road_area_pattern" { layer.isVisible = false; continue }
            if let bg = layer as? MLNBackgroundStyleLayer {
                bg.backgroundColor = c(p.land)
            } else if let f = layer as? MLNFillStyleLayer {
                switch id {
                case "water": f.fillColor = c(p.water)
                case "park":
                    f.fillColor = c(p.park); f.fillOutlineColor = c(p.park); f.fillOpacity = NSExpression(forConstantValue: 1)
                case "landcover_grass", "landcover_wood", "landcover_wetland":
                    // Liberty draws marshes with a bright grass pattern: plain green instead.
                    f.fillPattern = nil
                    f.fillColor = c(p.park); f.fillOutlineColor = c(p.park); f.fillOpacity = NSExpression(forConstantValue: 0.9)
                case "landuse_pitch", "landuse_track": f.fillColor = c(p.pitch)
                case "building":
                    f.fillColor = c(p.building); f.fillOutlineColor = c(p.buildingOutline)
                case "aeroway_fill": f.fillColor = c(p.airport)
                default:
                    if id.hasPrefix("landuse") || id.hasPrefix("landcover") {
                        f.fillColor = c(p.landuse); f.fillOpacity = NSExpression(forConstantValue: p.landuseOpacity)
                    }
                }
            } else if let e = layer as? MLNFillExtrusionStyleLayer, id == "building-3d" {
                e.fillExtrusionColor = c(p.building)
            } else if let l = layer as? MLNLineStyleLayer {
                if id.hasPrefix("waterway") { l.lineColor = c(p.water); continue }
                if id == "park_outline" || id.hasPrefix("landcover") || id.hasPrefix("park") { l.isVisible = false; continue }
                if id.hasPrefix("aeroway") { l.lineColor = c(p.runway); continue }
                if id.hasPrefix("boundary") { l.lineColor = c(p.border); continue }
                if id.contains("rail") { l.lineColor = c(p.rail); continue }
                guard id.hasPrefix("road_") || id.hasPrefix("bridge_") || id.hasPrefix("tunnel_") else { continue }
                if id.contains("casing") {
                    l.lineColor = c(id.contains("motorway") ? p.motorwayCasing : p.casing)
                } else if id.contains("motorway") {
                    l.lineColor = c(p.motorway)
                } else if id.contains("trunk_primary") {
                    l.lineColor = c(p.major)
                } else if id.contains("service_track") {
                    l.lineColor = c(p.service)
                } else if id.contains("path_pedestrian") {
                    l.lineColor = c(p.path)
                } else {
                    l.lineColor = c(p.minor)
                }
            } else if let s = layer as? MLNSymbolStyleLayer {
                if id.hasPrefix("highway-shield") || id == "road_shield_us" {
                    // OpenMapTiles sometimes joins overlapping route references with a semicolon.
                    // The fixed-size shield cannot fit "94;1"; show the first reference instead.
                    let ref: [Any] = ["to-string", ["get", "ref"]]
                    let separator: [Any] = ["index-of", ";", ref]
                    s.text = NSExpression(mglJSONObject: ["case", [">", separator, 0], ["slice", ref, 0, separator], ref])
                }
                if id.hasPrefix("highway-name") {
                    s.textColor = c(p.roadLabel); s.textHaloColor = c(p.roadHalo)
                    s.textHaloWidth = NSExpression(forConstantValue: 1.6)
                } else if let label = p.label, let halo = p.halo, !id.hasPrefix("vela") {
                    s.textColor = c(label); s.textHaloColor = c(halo)
                    s.textHaloWidth = NSExpression(forConstantValue: 1.1)
                }
            }
        }
    }

    /** Layers that only get in the way while driving: shop and bin icons, footpaths, buildings, one-way arrows. */
    private static func clutter(_ id: String) -> Bool {
        id.hasPrefix("poi_") || id == "building" || id == "building-3d" || id.contains("path_pedestrian")
            || id == "highway-name-path" || id.hasPrefix("road_one_way_arrow") || id.hasSuffix("_hatching")
            || ["landuse_pitch", "landuse_track", "landuse_cemetery", "landuse_hospital", "landuse_school",
                "aeroway_fill", "aeroway_runway", "aeroway_taxiway", "airport"].contains(id)
    }

    private static var savedLabelSizes: [String: NSExpression] = [:]
    private static var savedShieldSpacing: [String: NSExpression] = [:]
    private static var savedShieldPadding: [String: NSExpression] = [:]

    /** Strips the map to roads, water, parks and big road names while navigating, and puts it back after. */
    static func drive(_ style: MLNStyle, on: Bool) {
        for layer in style.layers where !layer.identifier.hasPrefix("vela") {
            let id = layer.identifier
            if clutter(id) { layer.isVisible = !on; continue }
            // Road number signs (M27, A27): Liberty repeats them every 200 points along every road, both
            // carriageways of a motorway included, a dozen at once near a junction. While driving, one
            // now and then is plenty, the way Waze shows them; the padding keeps two near each other apart.
            if let s = layer as? MLNSymbolStyleLayer, id.contains("shield") {
                if savedShieldSpacing[id] == nil {
                    savedShieldSpacing[id] = s.symbolSpacing
                    savedShieldPadding[id] = s.iconPadding
                }
                s.symbolSpacing = on ? NSExpression(forConstantValue: 900) : savedShieldSpacing[id]!
                s.iconPadding = on ? NSExpression(forConstantValue: 30) : savedShieldPadding[id]!
                continue
            }
            if let s = layer as? MLNSymbolStyleLayer, id == "highway-name-major" || id == "highway-name-minor" {
                if savedLabelSizes[id] == nil { savedLabelSizes[id] = s.textFontSize }
                s.textFontSize = on ? NSExpression(forConstantValue: id == "highway-name-major" ? 17 : 15) : savedLabelSizes[id]!
            }
        }
    }
}
