import Foundation
import CoreFoundation

/// Extracts only non-identifying display capabilities from a receiver's plist.
/// These fields are advertised properties, not proof that a session works.
public enum ReceiverCapabilities {
    public struct Display: Equatable {
        public let width: Int
        public let height: Int
        public let maxFPS: Int?
    }

    public static func displays(from body: Data) -> [Display]? {
        guard !body.isEmpty, body.count <= ReceiverProbe.maximumResponseBytes,
              let object = try? PropertyListSerialization.propertyList(from: body, options: [], format: nil),
              let root = object as? [String: Any], let entries = root["displays"] as? [Any],
              entries.count <= 16 else { return nil }
        func number(_ value: Any?, maximum: Int) -> Int? {
            guard let value = value as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite,
                  value.doubleValue.rounded() == value.doubleValue,
                  value.doubleValue >= 1, value.doubleValue <= Double(maximum) else { return nil }
            return value.intValue
        }
        var result: [Display] = []
        for entry in entries {
            guard let info = entry as? [String: Any],
                  let width = number(info["widthPixels"], maximum: 16384),
                  let height = number(info["heightPixels"], maximum: 16384) else { continue }
            result.append(Display(width: width, height: height, maxFPS: number(info["maxFPS"], maximum: 240)))
        }
        return result
    }
}
