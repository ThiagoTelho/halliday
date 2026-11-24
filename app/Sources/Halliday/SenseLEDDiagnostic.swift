// Optional, short-lived per-hand LED overrides for a diagnostic launch. Parsing is pure:
// callers opt in to reading a control file and restore normal camera sync when this returns empty.
// Format: {"expires_at": UNIX_SECONDS, "left": 6, "right": 5}; either hand is optional.

import Foundation
import CoreFoundation

enum SenseLEDDiagnostic {
    static func phases(data: Data?, now: TimeInterval) -> [String: UInt8] {
        guard now.isFinite, let data, !data.isEmpty, data.count <= 1024,
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              Set(fields.keys).isSubset(of: ["expires_at", "left", "right"]),
              let expiry = fields["expires_at"] as? NSNumber,
              CFGetTypeID(expiry) != CFBooleanGetTypeID()
        else { return [:] }
        let deadline = expiry.doubleValue
        guard deadline.isFinite, deadline > now, deadline <= now + 10 else { return [:] }

        var result: [String: UInt8] = [:]
        for hand in ["left", "right"] {
            guard let raw = fields[hand] else { continue }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let phase = UInt8(exactly: number.doubleValue), [1, 5, 6].contains(phase)
            else { return [:] }
            result[hand] = phase
        }
        return result
    }
}
